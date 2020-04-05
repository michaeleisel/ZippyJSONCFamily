//Copyright (c) 2018 Michael Eisel. All rights reserved.

#import <Foundation/Foundation.h>

CF_EXTERN_C_BEGIN

typedef CF_ENUM(size_t, JNTDecodingErrorType) {
    JNTDecodingErrorTypeNone,
    JNTDecodingErrorTypeKeyDoesNotExist,
    JNTDecodingErrorTypeValueDoesNotExist,
    JNTDecodingErrorTypeNumberDoesNotFit,
    JNTDecodingErrorTypeWrongType,
    JNTDecodingErrorTypeJSONParsingFailed,
};

static const NSInteger kJNTDecoderSize = 25;

#ifdef __cplusplus
struct JNTContext;
typedef JNTContext *ContextPointer;
#else
struct ContextDummy {
};
typedef struct ContextDummy *ContextPointer;
#endif

struct JNTElementStorage {
    void *doc;
    size_t offset;
};

struct JNTContext;

struct JNTDecoderStorage {
    struct JNTElementStorage storage;
    struct JNTContext *context;
};

#ifdef __cplusplus
struct JNTDecoder;
#else
typedef struct JNTDecoderStorage JNTDecoder;
#endif
//typedef JNTDecoder Decoder;
typedef JNTDecoder *DecoderPointer;

bool JNTDocumentIsEmpty(DecoderPointer decoder);
void JNTClearError(ContextPointer context);
ContextPointer JNTGetContext(DecoderPointer decoder);
bool JNTDocumentErrorDidOccur(DecoderPointer decoder);
bool JNTDocumentValueIsInteger(DecoderPointer decoder);
bool JNTDocumentValueIsDouble(DecoderPointer decoder);
BOOL JNTHasVectorExtensions();
ContextPointer JNTCreateContext(const char *originalString, uint32_t originalStringLength, const char *negInfString, const char *posInfString, const char *nanString);
DecoderPointer JNTDocumentFromJSON(ContextPointer context, const void *data, NSInteger length, bool convertCase, const char * *retryReason, bool fullPrecisionFloatParsing);
BOOL JNTDocumentContains(DecoderPointer iterator, const char *key);
void JNTProcessError(ContextPointer context, void (^block)(const char *description, JNTDecodingErrorType type, DecoderPointer value, const char *key));
bool JNTErrorDidOccur(ContextPointer context);
JNTDecoder JNTDocumentFetchValue(DecoderPointer decoder, const char *key);
BOOL JNTDocumentDecodeNil(DecoderPointer documentPtr);
void JNTReleaseContext(ContextPointer context);
DecoderPointer JNTDocumentFromJSON(ContextPointer context, const void *data, NSInteger length, bool convertCase, const char * *retryReason, bool fullPrecisionFloatParsing);
void JNTDocumentNextArrayElement(DecoderPointer iterator, bool *isAtEnd);
void JNTUpdateFloatingPointStrings(const char *posInfString, const char *negInfString, const char *nanString);
bool JNTDocumentValueIsArray(DecoderPointer iterator);
bool JNTDocumentValueIsDictionary(DecoderPointer iterator);
NSArray <NSString *> *JNTDocumentAllKeys(DecoderPointer decoder);
NSArray <id> *JNTDocumentCodingPath(DecoderPointer iterator);
void JNTDocumentForAllKeyValuePairs(DecoderPointer iterator, void (^callback)(const char *key, DecoderPointer iterator));
void JNTConvertSnakeToCamel(DecoderPointer iterator);

double JNTDocumentDecode__Double(DecoderPointer value);
float JNTDocumentDecode__Float(DecoderPointer value);
NSDate *JNTDocumentDecode__Date(DecoderPointer value);
void *JNTDocumentDecode__Data(DecoderPointer value, int32_t *outLength);
void JNTRunTests();
bool JNTDocumentValueIsNumber(DecoderPointer value);
const char *JNTDocumentDecode__DecimalString(DecoderPointer value, int32_t *outLength);
void JNTReleaseValue(DecoderPointer decoder);
DecoderPointer JNTDocumentCreateCopy(DecoderPointer decoder);
DecoderPointer JNTDocumentEnterStructureAndReturnCopy(DecoderPointer decoder, bool *isEmpty);

NSInteger JNTDocumentGetArrayCount(DecoderPointer value);

@interface JNTCodingPath : NSObject

- (instancetype)initWithStringValue:(NSString *)stringValue intValue:(NSInteger)intValue;

@property (strong, nonatomic) NSString *stringValue;
@property (nonatomic) NSInteger intValue;

@end

#define DECODE_KEYED_HEADER(A, B) DECODE_KEYED_HEADER_NAMED(A, B, A)

#define DECODE_KEYED_HEADER_NAMED(A, B, C) \
A JNTDocumentDecodeKeyed__##C(DecoderPointer value, const char *key);

#define DECODE_HEADER(A, B) DECODE_HEADER_NAMED(A, B, A)

#define DECODE_HEADER_NAMED(A, B, C) \
A JNTDocumentDecode__##C(DecoderPointer value);

#define ENUMERATE(F) \
F(int8_t, int64_t); \
F(uint8_t, int64_t); \
F(int16_t, int64_t); \
F(uint16_t, int64_t); \
F(int32_t, int64_t); \
F(uint32_t, int64_t); \
F(int64_t, int64_t); \
F(uint64_t, uint64_t); \
F##_NAMED(bool, bool, Bool); \
F##_NAMED(const char *, const char *, String); \
F##_NAMED(NSInteger, int64_t, Int); \
F##_NAMED(NSUInteger, uint64_t, UInt);

ENUMERATE(DECODE_HEADER);

CF_EXTERN_C_END
