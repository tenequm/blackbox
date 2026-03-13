#import <Foundation/Foundation.h>
#import <AVFAudio/AVFAudio.h>

NS_ASSUME_NONNULL_BEGIN

/// Executes a block and catches any ObjC NSException, returning it instead of crashing.
/// Returns nil if the block executed successfully.
///
/// WARNING: Unreliable when the block contains Swift code. The Swift compiler may optimize
/// away the NS_NOESCAPE block trampoline in release builds, removing ObjC frames from the
/// unwind path. Use the purpose-built wrappers below for AVAudioEngine operations.
FOUNDATION_EXPORT NSException *_Nullable ObjCTryBlock(void (NS_NOESCAPE ^block)(void));

// MARK: - AVAudioEngine safe wrappers
//
// Purpose-built methods where the entire throw-to-catch chain is pure ObjC.
// The Swift compiler cannot eliminate these frames, so @try/@catch is guaranteed to work.

/// Get engine's inputNode. Returns nil + exception if no audio device exists.
FOUNDATION_EXPORT AVAudioInputNode *_Nullable ObjCGetInputNode(
    AVAudioEngine *engine,
    NSException *_Nullable *_Nullable outException);

/// Install tap on audio node. Returns exception on failure, nil on success.
FOUNDATION_EXPORT NSException *_Nullable ObjCInstallTap(
    AVAudioNode *node,
    uint32_t bus,
    AVAudioFrameCount bufferSize,
    AVAudioFormat *_Nullable format,
    AVAudioNodeTapBlock block);

/// Remove tap from audio node. Returns exception on failure, nil on success.
FOUNDATION_EXPORT NSException *_Nullable ObjCRemoveTap(
    AVAudioNode *node,
    uint32_t bus);

/// Start audio engine. Returns exception on failure, nil on success.
/// NSError from -startAndReturnError: is returned via outError.
FOUNDATION_EXPORT NSException *_Nullable ObjCStartEngine(
    AVAudioEngine *engine,
    NSError *_Nullable *_Nullable outError);

/// Stop audio engine safely. Returns exception on failure, nil on success.
FOUNDATION_EXPORT NSException *_Nullable ObjCStopEngine(AVAudioEngine *engine);

NS_ASSUME_NONNULL_END
