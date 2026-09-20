#import <Foundation/Foundation.h>

/// A C face for llama.cpp, deliberately exposing none of its types.
///
/// whisper.cpp and llama.cpp each vendor their own copy of ggml, and the two
/// copies are not the same version: `ggml_prec` alone has two members in one
/// and seven in the other. Importing both as Clang modules into the same Swift
/// module is therefore a hard error, and the versions cannot simply be aligned
/// because the transcription framework is a custom build.
///
/// So llama.cpp is never imported into Swift at all. Exactly one translation
/// unit, LlamaBridge.m, sees its headers, and everything crossing back into
/// Swift is a primitive. The transcription engine keeps its own ggml, this
/// keeps its own, and they never meet.
///
/// The generation loop lives on this side of the boundary for the same reason:
/// it is the part that needs llama's types.

NS_ASSUME_NONNULL_BEGIN

/// What went wrong, as a cause rather than a message. The wording the user
/// reads is written in Swift with the rest of the interface copy.
typedef NS_ENUM(NSInteger, MMDLlamaStatus) {
    MMDLlamaStatusOK = 0,
    /// The file is missing, truncated, or not a model.
    MMDLlamaStatusLoadFailed,
    /// The model loaded but no inference context could be made for it.
    MMDLlamaStatusContextFailed,
    /// The chat template could not be applied, or tokenizing failed.
    MMDLlamaStatusPromptFailed,
    /// The transcript does not leave the model room to answer.
    MMDLlamaStatusPromptTooLong,
    /// Inference failed part way through.
    MMDLlamaStatusDecodeFailed,
    /// The caller's cancellation block returned true.
    MMDLlamaStatusCancelled,
    /// The model produced nothing usable.
    MMDLlamaStatusEmpty,
    /// The token budget ran out before the model finished its answer, so what
    /// it produced stops mid-thought.
    MMDLlamaStatusTruncated,
};

/// An opaque loaded model plus its inference context.
typedef struct MMDLlamaSession MMDLlamaSession;

/// Loads the GGUF at `path`. Returns NULL and sets `status` on failure.
/// Not thread safe; the caller serialises.
///
/// `cancelled` is polled while the file is read. Reading several gigabytes can
/// take twenty seconds from cold, and without this the queue stays occupied by
/// a dictation the user gave up on long before it finished loading.
MMDLlamaSession *_Nullable mmd_llama_open(const char *path,
                                          BOOL (^cancelled)(void),
                                          MMDLlamaStatus *status);

/// Frees the context and the model. Safe with NULL.
void mmd_llama_close(MMDLlamaSession *_Nullable session);

/// Generates a continuation of `prompt`, which must already be formatted for
/// this model.
///
/// Formatting deliberately happens in Swift. llama.cpp's own
/// `llama_chat_apply_template` does not run the Jinja template stored in a
/// GGUF: it recognises a fixed list of older formats and fails outright on
/// anything else, which is every model worth shipping today. Worse, where it
/// does recognise a family it applies its own idea of that family's format,
/// which silently differs from what the model was trained on.
///
/// Returns a NUL-terminated UTF-8 string the caller must `free`, or NULL with
/// `status` set. `cancelled` is polled between tokens: generation cannot be
/// interrupted inside one, but a token is milliseconds.
/// `tokens_in` and `tokens_out` receive the prompt and generated token counts.
/// Both are by-products: the prompt has to be tokenized before it can be fed to
/// the model, and generation produces exactly one token per pass, so neither
/// costs anything to report. They are the same quantities a llama.cpp server
/// reports as prompt and completion tokens. Pass NULL for either to ignore it.
char *_Nullable mmd_llama_generate(MMDLlamaSession *session,
                                   const char *prompt,
                                   int max_new_tokens,
                                   BOOL (^cancelled)(void),
                                   int *_Nullable tokens_in,
                                   int *_Nullable tokens_out,
                                   MMDLlamaStatus *status);

NS_ASSUME_NONNULL_END
