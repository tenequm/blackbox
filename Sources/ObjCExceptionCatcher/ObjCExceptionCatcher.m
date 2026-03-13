#import "ObjCExceptionCatcher.h"

NSException *_Nullable ObjCTryBlock(void (NS_NOESCAPE ^block)(void)) {
  @try {
    block();
    return nil;
  } @catch (NSException *exception) {
    return exception;
  }
}

// MARK: - AVAudioEngine safe wrappers

AVAudioInputNode *_Nullable ObjCGetInputNode(AVAudioEngine *engine,
                                              NSException *_Nullable *outException) {
  @try {
    return engine.inputNode;
  } @catch (NSException *e) {
    if (outException) *outException = e;
    return nil;
  }
}

NSException *_Nullable ObjCInstallTap(AVAudioNode *node,
                                       uint32_t bus,
                                       AVAudioFrameCount bufferSize,
                                       AVAudioFormat *format,
                                       AVAudioNodeTapBlock block) {
  @try {
    [node installTapOnBus:bus bufferSize:bufferSize format:format block:block];
    return nil;
  } @catch (NSException *e) {
    return e;
  }
}

NSException *_Nullable ObjCRemoveTap(AVAudioNode *node, uint32_t bus) {
  @try {
    [node removeTapOnBus:bus];
    return nil;
  } @catch (NSException *e) {
    return e;
  }
}

NSException *_Nullable ObjCStartEngine(AVAudioEngine *engine,
                                        NSError *_Nullable *outError) {
  @try {
    [engine startAndReturnError:outError];
    return nil;
  } @catch (NSException *e) {
    return e;
  }
}

NSException *_Nullable ObjCStopEngine(AVAudioEngine *engine) {
  @try {
    [engine stop];
    return nil;
  } @catch (NSException *e) {
    return e;
  }
}
