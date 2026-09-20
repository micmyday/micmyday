#import "LlamaBridge.h"

#import <llama/llama.h>

#include <stdlib.h>
#include <string.h>

/// The context window. Dictations are short, and every token of context costs
/// memory that has to be found alongside the weights.
static const uint32_t kContextTokens = 4096;

/// Room the reply is guaranteed, so a long transcript is refused up front
/// rather than producing a rewrite that stops mid-sentence.
static const int kReservedForReply = 512;

struct MMDLlamaSession {
    struct llama_model *model;
    struct llama_context *context;
};

static void mmd_backend_once(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ llama_backend_init(); });
}

/// Both callbacks below are handed a pointer to one of these. Neither outlives
/// the call it was made for.
typedef struct {
    __unsafe_unretained BOOL (^cancelled)(void);
} MMDCancelBox;

/// llama's loading callback: returning false stops the read.
static bool mmd_loading_should_continue(float progress, void *user_data) {
    (void)progress;
    MMDCancelBox *box = (MMDCancelBox *)user_data;
    return !box->cancelled();
}

/// ggml's abort callback: returning true stops the computation. This is what
/// makes a long prompt interruptible, since evaluating one is a single call
/// that would otherwise run to completion between cancellation checks.
static bool mmd_should_abort(void *user_data) {
    MMDCancelBox *box = (MMDCancelBox *)user_data;
    return box->cancelled();
}

MMDLlamaSession *mmd_llama_open(const char *path,
                                BOOL (^cancelled)(void),
                                MMDLlamaStatus *status) {
    mmd_backend_once();

    MMDCancelBox box = { .cancelled = cancelled };

    struct llama_model_params model_params = llama_model_default_params();
    // Everything on the GPU. The offered models are chosen to fit, and the
    // Metal path is several times faster than the CPU one.
    model_params.n_gpu_layers = 999;
    model_params.progress_callback = mmd_loading_should_continue;
    model_params.progress_callback_user_data = &box;

    struct llama_model *model = llama_model_load_from_file(path, model_params);
    if (model == NULL) {
        // Stopping the read deliberately looks exactly like a failed read from
        // here, so the two are told apart by asking who asked.
        *status = cancelled() ? MMDLlamaStatusCancelled : MMDLlamaStatusLoadFailed;
        return NULL;
    }

    struct llama_context_params context_params = llama_context_default_params();
    context_params.n_ctx = kContextTokens;
    context_params.n_batch = kContextTokens;

    struct llama_context *context = llama_init_from_model(model, context_params);
    if (context == NULL) {
        llama_model_free(model);
        *status = MMDLlamaStatusContextFailed;
        return NULL;
    }

    MMDLlamaSession *session = calloc(1, sizeof(MMDLlamaSession));
    if (session == NULL) {
        llama_free(context);
        llama_model_free(model);
        *status = MMDLlamaStatusContextFailed;
        return NULL;
    }
    session->model = model;
    session->context = context;
    *status = MMDLlamaStatusOK;
    return session;
}

void mmd_llama_close(MMDLlamaSession *session) {
    if (session == NULL) return;
    if (session->context) llama_free(session->context);
    if (session->model) llama_model_free(session->model);
    free(session);
}

/// Low temperature, because this is a rewrite and not a composition: the words
/// are the user's, and the model's job is to tidy them rather than to have
/// ideas about them.
static struct llama_sampler *mmd_make_sampler(void) {
    struct llama_sampler_chain_params params = llama_sampler_chain_default_params();
    params.no_perf = true;
    struct llama_sampler *chain = llama_sampler_chain_init(params);
    if (chain == NULL) return NULL;
    llama_sampler_chain_add(chain, llama_sampler_init_top_k(40));
    llama_sampler_chain_add(chain, llama_sampler_init_top_p(0.9f, 1));
    llama_sampler_chain_add(chain, llama_sampler_init_temp(0.3f));
    llama_sampler_chain_add(chain, llama_sampler_init_dist(LLAMA_DEFAULT_SEED));
    return chain;
}

char *mmd_llama_generate(MMDLlamaSession *session,
                         const char *prompt,
                         int max_new_tokens,
                         BOOL (^cancelled)(void),
                         int *tokens_in,
                         int *tokens_out,
                         MMDLlamaStatus *status) {
    const struct llama_vocab *vocab = llama_model_get_vocab(session->model);
    if (vocab == NULL) {
        *status = MMDLlamaStatusPromptFailed;
        return NULL;
    }

    const int prompt_bytes = (int)strlen(prompt);
    const int capacity = prompt_bytes + 8;
    llama_token *tokens = malloc(sizeof(llama_token) * (size_t)capacity);
    if (tokens == NULL) {
        *status = MMDLlamaStatusPromptFailed;
        return NULL;
    }

    // add_special adds whatever beginning-of-sequence token this model's config
    // calls for, which is why the formats in Swift never write one themselves.
    // parse_special makes the turn markers tokenize as the single special
    // tokens they are rather than as their spelling.
    const int token_count = llama_tokenize(vocab, prompt, prompt_bytes, tokens, capacity, true, true);
    if (token_count <= 0) {
        free(tokens);
        *status = MMDLlamaStatusPromptFailed;
        return NULL;
    }
    if (tokens_in) *tokens_in = token_count;

    const int room_for_reply = (int)kContextTokens - token_count;
    if (room_for_reply < kReservedForReply) {
        free(tokens);
        *status = MMDLlamaStatusPromptTooLong;
        return NULL;
    }
    // Never allow generation to run past the end of the context. Admitting a
    // prompt on a 512-token reservation and then letting it generate thousands
    // would fail the decode part way and throw away a rewrite that had nearly
    // finished.
    if (max_new_tokens > room_for_reply) max_new_tokens = room_for_reply;

    // Each rewrite starts from nothing: the previous transcript must not
    // influence this one, and the memory it used is wanted back.
    llama_memory_clear(llama_get_memory(session->context), true);

    struct llama_sampler *sampler = mmd_make_sampler();
    if (sampler == NULL) {
        free(tokens);
        *status = MMDLlamaStatusContextFailed;
        return NULL;
    }

    // Grown as needed. Pieces are byte fragments, so a multi-byte character can
    // arrive split across two tokens; accumulating raw bytes and converting
    // once at the end means no character is ever cut in half.
    size_t output_capacity = 4096;
    size_t output_length = 0;
    char *output = malloc(output_capacity);
    if (output == NULL) {
        llama_sampler_free(sampler);
        free(tokens);
        *status = MMDLlamaStatusDecodeFailed;
        return NULL;
    }

    // Evaluating the prompt is a single decode that can run for seconds on a
    // long dictation. Polling between tokens cannot interrupt that, so ggml is
    // given something to ask on the way through.
    MMDCancelBox box = { .cancelled = cancelled };
    llama_set_abort_callback(session->context, mmd_should_abort, &box);

    struct llama_batch batch = llama_batch_get_one(tokens, token_count);
    llama_token next = 0;
    MMDLlamaStatus outcome = MMDLlamaStatusOK;
    BOOL finished = NO;
    int generated_count = 0;

    for (int generated = 0; generated < max_new_tokens; generated++) {
        if (cancelled()) {
            outcome = MMDLlamaStatusCancelled;
            break;
        }

        if (llama_decode(session->context, batch) != 0) {
            outcome = cancelled() ? MMDLlamaStatusCancelled : MMDLlamaStatusDecodeFailed;
            break;
        }

        next = llama_sampler_sample(sampler, session->context, -1);
        if (llama_vocab_is_eog(vocab, next)) {
            // Counted, though it produces no text. A llama.cpp server counts
            // the end-of-generation token it sampled, and the whole value of
            // these figures is that they can be compared with a provider's.
            generated_count++;
            finished = YES;
            break;
        }
        llama_sampler_accept(sampler, next);

        // A negative result is llama.cpp asking for a bigger buffer. Treating it
        // as zero would silently drop a token out of the middle of the text.
        char piece[256];
        char *piece_heap = NULL;
        char *piece_bytes = piece;
        int written = llama_token_to_piece(vocab, next, piece, (int)sizeof(piece), 0, false);
        if (written < 0) {
            piece_heap = malloc((size_t)(-written));
            if (piece_heap == NULL) {
                outcome = MMDLlamaStatusDecodeFailed;
                break;
            }
            piece_bytes = piece_heap;
            written = llama_token_to_piece(vocab, next, piece_heap, -written, 0, false);
            if (written < 0) written = 0;
        }
        if (written > 0) {
            // A loop rather than a single doubling: correct whatever the piece
            // size turns out to be, instead of only for pieces smaller than the
            // buffer already is.
            while (output_length + (size_t)written + 1 > output_capacity) {
                output_capacity *= 2;
            }
            char *grown = realloc(output, output_capacity);
            if (grown == NULL) {
                free(piece_heap);
                outcome = MMDLlamaStatusDecodeFailed;
                break;
            }
            output = grown;
            memcpy(output + output_length, piece_bytes, (size_t)written);
            output_length += (size_t)written;
        }
        free(piece_heap);
        // Counted where the token is kept, not at the top of the loop: a token
        // sampled and then discarded as end-of-generation was never produced,
        // and the count has to agree with the text.
        generated_count++;

        batch = llama_batch_get_one(&next, 1);
    }

    llama_sampler_free(sampler);
    free(tokens);
    // The box lives on this stack frame. Leaving the context pointing at it
    // would hand ggml a dangling pointer on the next rewrite.
    llama_set_abort_callback(session->context, NULL, NULL);

    // Reported whatever the outcome: a cancelled or truncated run still read
    // its prompt and still generated, and the work it did was still done.
    if (tokens_out) *tokens_out = generated_count;

    if (outcome != MMDLlamaStatusOK) {
        free(output);
        *status = outcome;
        return NULL;
    }
    // The model never said it was done, so whatever is here stops mid-thought.
    // The caller keeps the original transcript, which is better than inserting
    // half a sentence.
    if (!finished) {
        free(output);
        *status = MMDLlamaStatusTruncated;
        return NULL;
    }
    if (output_length == 0) {
        free(output);
        *status = MMDLlamaStatusEmpty;
        return NULL;
    }

    output[output_length] = '\0';
    *status = MMDLlamaStatusOK;
    return output;
}
