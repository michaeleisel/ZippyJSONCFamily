//Copyright (c) 2018 Michael Eisel. All rights reserved.

// NOTE: ARC is disabled for this file

#import "simdjson.h"
#import "JSONSerialization.h"
#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>
#import <stdio.h>
#import <math.h>
#import <string.h>
#import <atomic>
#import <mutex>
#import <typeinfo>
#import <deque>
#import <dispatch/dispatch.h>

using namespace simdjson;

static inline char JNTStringPop(char **string) {
    char c = **string;
    (*string)++;
    return c;
}

BOOL JNTHasVectorExtensions() {
#ifdef __SSE4_2__
  return true;
#else
  return false;
#endif
}

struct JNTDecoder;

struct JNTDecodingError {
    std::string description = "";
    JNTDecodingErrorType type = JNTDecodingErrorTypeNone;
    DecoderPointer value = NULL;
    std::string key = "";
    JNTDecodingError() {
    }
    JNTDecodingError(std::string description, JNTDecodingErrorType type, DecoderPointer value, std::string key) : description(description), type(type), value(value), key(key) {
    }
};

struct JNTContext { // static for classes?
public:
    dom::parser parser;
    dom::element root;
    JNTDecodingError error;
    std::string snakeCaseBuffer;

    std::string posInfString;
    std::string negInfString;
    std::string nanString;

    const char *originalString;
    uint32_t originalStringLength;

    JNTContext(const char *originalString, uint32_t originalStringLength, std::string posInfString, std::string negInfString, std::string nanString) : originalString(originalString), originalStringLength(originalStringLength), posInfString(posInfString), negInfString(negInfString), nanString(nanString) {
    }
};

struct JNTDecoder {
    dom::element element;
    JNTContext *context;
};

static_assert(sizeof(JNTDecoder) == sizeof(JNTDecoderStorage), "");
static_assert(sizeof(JNTDecoder[2]) == sizeof(JNTDecoderStorage[2]), "");
static_assert(std::is_trivially_copyable<JNTDecoder>(), "");
static_assert(std::is_trivially_copyable<dom::element>(), "");
// static_assert(std::is_trivial<JNTDecoder>(), "");

static inline JNTDecoder JNTCreateDecoder(dom::element element, JNTContext *context) {
    JNTDecoder decoder;
    decoder.element = element;
    decoder.context = context;
    return decoder;
}

// Pre-condition: decoder is known to be an array
bool JNTDocumentIsEmpty(DecoderPointer decoder) {
    dom::array array = decoder->element;
    return !(array.begin() != array.end());
}

void JNTClearError(ContextPointer context) {
    context->error = JNTDecodingError();
}

bool JNTErrorDidOccur(ContextPointer context) {
    return context->error.type != JNTDecodingErrorTypeNone;
}

bool JNTDocumentErrorDidOccur(DecoderPointer decoder) {
    return JNTErrorDidOccur(decoder->context);
}

ContextPointer JNTGetContext(DecoderPointer decoder) {
    return decoder->context;
}

void JNTProcessError(ContextPointer context, void (^block)(const char *description, JNTDecodingErrorType type, DecoderPointer value, const char *key)) {
    JNTDecodingError &error = context->error;
    block(error.description.c_str(), error.type, error.value, error.key.c_str());
}

typedef JNTDecoder *DecoderPointer;

static const char *JNTStringForType(dom::element_type type) {
    switch (type) {
        case dom::element_type::NULL_VALUE:
            return "null";
        case dom::element_type::BOOL:
            return "Bool";
        case dom::element_type::OBJECT:
            return "Dictionary";
        case dom::element_type::ARRAY:
            return "Array";
        case dom::element_type::STRING:
            return "String";
        case dom::element_type::INT64:
        case dom::element_type::UINT64:
        case dom::element_type::DOUBLE:
            return "Number";
        default:
            return "?";
    }
}

static inline void JNTSetError(std::string description, JNTDecodingErrorType type, JNTContext *context, JNTDecoder *decoder, std::string key) {
    if (context->error.type != JNTDecodingErrorTypeNone) {
        return;
    }
    JNTDecoder *value = decoder ? new JNTDecoder(*decoder) : NULL;
    context->error = JNTDecodingError(description, type, value, key);
}

static void JNTHandleJSONParsingFailed(error_code code, JNTContext *context) {
    std::ostringstream oss;
    oss << "The given data was not valid JSON. Error: " << code;
    JNTSetError(oss.str(), JNTDecodingErrorTypeJSONParsingFailed, context, NULL, "");
}

static void JNTHandleWrongType(JNTDecoder *decoder, dom::element_type type, const char *expectedType) {
    JNTDecodingErrorType errorType = type == dom::element_type::NULL_VALUE ? JNTDecodingErrorTypeValueDoesNotExist : JNTDecodingErrorTypeWrongType;
    std::ostringstream oss;
    oss << "Expected to decode " << expectedType << " but found " << JNTStringForType(type) << " instead.";
    JNTSetError(oss.str(), errorType, decoder->context, decoder, "");
}

static void JNTHandleMemberDoesNotExist(JNTDecoder *decoder, const char *key) {
    std::ostringstream oss;
    oss << "No value associated with " << key << ".";
    JNTSetError(oss.str(), JNTDecodingErrorTypeKeyDoesNotExist, decoder->context, decoder, key);
}

template <typename T>
static void JNTHandleNumberDoesNotFit(JNTDecoder *decoder, T number, const char *type) {
    //char *description = nullptr;
    NS_VALID_UNTIL_END_OF_SCOPE NSString *string = [@(number) description];
    std::ostringstream oss;
    oss << "Parsed JSON number " << string.UTF8String << " does not fit.";
    std::string description = oss.str();
    JNTSetError(description, JNTDecodingErrorTypeNumberDoesNotFit, decoder->context, decoder, "");
}

static inline bool JNTIsLower(char c) {
    return 'a' <= c && c <= 'z';
}

static inline bool JNTIsUpper(char c) {
    return 'A' <= c && c <= 'Z';
}

static inline char JNTToUpper(char c) {
    return JNTIsLower(c) ? c + ('A' - 'a') : c;
}

static inline char JNTToLower(char c) {
    return JNTIsUpper(c) ? c + ('a' - 'A') : c;
}

static inline uint32_t JNTReplaceSnakeWithCamel(std::string &buffer, char *string) {
    buffer.erase();
    char *end = string + strlen(string);
    char *currString = string;
    while (currString < end) {
        if (*currString != '_') {
            break;
        }
        buffer.push_back('_');
        currString++;
    }
    if (currString == end) {
        return (uint32_t)(end - string);
    }
    char *originalEnd = end;
    end--;
    while (*end == '_') {
        end--;
    }
    end++;
    bool didHitUnderscore = false;
    size_t leadingUnderscoreCount = currString - string;
    while (currString < end) {
        char first = JNTStringPop(&currString);
        buffer.push_back(JNTToUpper(first));
        while (currString < end && *currString != '_') {
            char c = JNTStringPop(&currString);
            buffer.push_back(JNTToLower(c));
        }
        while (currString < end && *currString == '_') {
            didHitUnderscore = true;
            currString++;
        }
    }
    if (!didHitUnderscore) {
        return (uint32_t)(originalEnd - string);
    }
    buffer[leadingUnderscoreCount] = JNTToLower(buffer[leadingUnderscoreCount]); // If the first got capitalized
    for (NSInteger i = 0; i < originalEnd - end; i++) {
        buffer.push_back('_');
    }
    memcpy(string, buffer.c_str(), buffer.size() + 1);
    uint32_t size = (uint32_t)buffer.size();
    return size;
}

void JNTConvertSnakeToCamel(DecoderPointer decoder) {
    dom::object object = decoder->element;
    for (auto it = object.begin(); it != object.end(); ++it) {
        char *string = (char *)it.key_c_str();
        uint32_t length = JNTReplaceSnakeWithCamel(decoder->context->snakeCaseBuffer, string);
        memcpy(string - sizeof(length), &length, sizeof(length));
    }
}

static inline char JNTChecker(const char *s) {
    char has = '\0';
    while (*s != '\0') {
        has |= *s;
        s++;
    }
    return has;
}

static inline char JNTCheckHelper(dom::element &element) {
    char has = '\0';
    if (element.is<dom::object>()) {
        dom::object object = element;
        for (auto [key, value] : object) {
            has |= JNTChecker(key.data());
            if (value.is<dom::object>() || value.is<dom::array>()) {
                has |= JNTCheckHelper(value);
            }
        }
    } else if (element.is<dom::array>()) {
        dom::array array = element;
        for (const auto member : array) {
            if (member.is<dom::object>() || member.is<dom::array>()) {
                has |= JNTCheckHelper(element);
            }
        }
    }
    return has;
}

// Check if there are any non-ASCII chars in the dictionary keys
static inline bool JNTCheck(dom::element &element) {
    return (JNTCheckHelper(element) & 0x80) != '\0';
}

ContextPointer JNTCreateContext(const char *originalString, uint32_t originalStringLength, const char *negInfString, const char *posInfString, const char *nanString) {
    return new JNTContext(originalString, originalStringLength, std::string(posInfString), std::string(negInfString), std::string(nanString));
}

static uint64_t kDataLimit = (1ULL << 32) - 1;

DecoderPointer JNTDocumentFromJSON(ContextPointer context, const void *data, NSInteger length, bool convertCase, const char * *retryReason, bool fullPrecisionFloatParsing) {
    if (length > kDataLimit) {
        *retryReason = "The length of the JSON data is too long (see kDataLimit for the max)";
    }
    simdjson::padded_string ps = simdjson::padded_string((char *)data, length);
    auto result = context->parser.parse(ps);
    if (result.error()) {
        if (result.error() != NUMBER_ERROR) { // retry number errors
            JNTHandleJSONParsingFailed(result.error(), context);
        } else {
            *retryReason = "Either the JSON is malformed, e.g. passing a number as the root object, or an integer was too large (couldn't fit in a 64-bit unsigned integer)";
        }
        return NULL;
    }
    context->root = result.value();
    if (JNTCheck(context->root)) {
        *retryReason = "One or more keys had non-ASCII characters";
        return NULL;
    } else {
        JNTDecoder decoder;
        decoder.element = context->root;
        decoder.context = context;
        return &decoder;
    }
}

void JNTReleaseContext(JNTContext *context) {
    delete context;
}

BOOL JNTDocumentContains(DecoderPointer decoder, const char *key) {
    // todo: make sure all functions match their declarations
    return decoder->element.at_key(key).error() == SUCCESS;
}

template <typename T, typename U>
static inline T JNTDocumentDecode(DecoderPointer decoder) {
    simdjson_result<U> value = decoder->element.get<U>();
    if (value.error()) {
        JNTHandleWrongType(decoder, decoder->element.type(), typeid(T).name());
    }
    return (T)value.value();
}

template <typename U = double>
inline double JNTDocumentDecode(DecoderPointer decoder) {
    if (decoder->element.is<double>()) {
        return decoder->element;
    } else {
        if (decoder->element.is<std::string_view>()) {
            std::string_view string = decoder->element;
            if (string == decoder->context->posInfString) {
                return INFINITY;
            } else if (string == decoder->context->negInfString) {
                return -INFINITY;
            } else if (string == decoder->context->nanString) {
                return NAN;
            }
        }
        JNTHandleWrongType(decoder, decoder->element.type(), "double/float");
        return 0;
    }
}

template <typename U = double>
inline float JNTDocumentDecode(DecoderPointer decoder) {
    return (float)JNTDocumentDecode<double, double>(decoder);
}

// Pre-condition: element is an array type
NSInteger JNTDocumentGetArrayCount(DecoderPointer decoder) {
    NSInteger count = 0;
    for (auto it = decoder->element.begin(); it != decoder->element.end(); ++it) {
        count++;
    }
    return count;
}

// Pre-condition: isAtEnd is known to be false
void JNTDocumentNextArrayElement(DecoderPointer decoder, dom::array::iterator iterator, bool *isAtEnd) {
    assert(!*isAtEnd);
    ++iterator;
    dom::array array = decoder->element;
    if (!(iterator != array.end())) {
        *isAtEnd = true;
    }
}

BOOL JNTDocumentDecodeNil(DecoderPointer decoder) {
    return decoder->element.is_null();
}

static bool JNTIteratorsEqual(dom::element &e1, dom::element &e2) {
    const auto ptr1 = (simdjson::internal::tape_ref *)&e1;
    auto index1 = ptr1->json_index;
    const auto ptr2 = (simdjson::internal::tape_ref *)&e2;
    auto index2 = ptr2->json_index;
    assert(ptr1->doc == ptr2->doc);
    return index1 == index2;
}

/*NSMutableArray <id> *JNTDocumentCodingPathHelper(dom::element &element, dom::element &targetElement) {
    if (element.is<dom::array>()) {
        dom::array array = element;
        NSInteger i = 0;
        for (auto member : array) {
            if (JNTIteratorsEqual(member, targetElement)) {
                return [@[@(i)] mutableCopy];
            } else if (member.is<dom::array>() || member.is<dom::object>()) {
                NSMutableArray *codingPath = JNTDocumentCodingPathHelper(member, targetElement);
                if (codingPath) {
                    [codingPath insertObject:@(i) atIndex:0];
                    return codingPath;
                }
            }
            i++;
        }
    } else if (element.is<dom::object>()) {
        dom::object object = element;
        for (auto [key, value] : object) {
            if (JNTIteratorsEqual(&iterator, targetIterator)) {
                return [@[@(key)] mutableCopy];
            }
            if (JNTIteratorsEqual(&iterator, targetIterator)) {
                return [@[@(key)] mutableCopy];
            } else if (iterator.is_object_or_array()) {
                NSMutableArray *codingPath = JNTDocumentCodingPathHelper(iterator, targetIterator);
                if (codingPath) {
                    [codingPath insertObject:@(key) atIndex:0];
                    return codingPath;
                }
            }
        }
    }
    return nil;
}*/

NSArray <id> *JNTDocumentCodingPath(DecoderPointer targetDecoder) {
    dom::element &element = targetDecoder->context->root;
    if (JNTIteratorsEqual(element, targetDecoder->element)) {
        return @[];
    }
    //NSMutableArray *array = JNTDocumentCodingPathHelper(element, &targetDecoder->element);
    //return array ? [array copy] : @[];
    return @[];
}

NSArray <NSString *> *JNTDocumentAllKeys(DecoderPointer decoder) {
    NSMutableArray <NSString *>*keys = [NSMutableArray array];
    dom::object object = decoder->element;
    for (auto [key, value] : object) {
        const char *cString = key.data();
        [keys addObject:@(cString)];
    }
    return [keys copy];
}

void JNTDocumentForAllKeyValuePairs(DecoderPointer decoderOriginal, void (^callback)(const char *key, dom::element element)) {
    // todo: Make a copy of the iterator?
    const auto &object = decoderOriginal->element.get<dom::object>();
    if (object.error()) {
        JNTHandleWrongType(decoderOriginal, decoderOriginal->element.type(), "dictionary");
        return;
    }
    for (auto [key, value] : object) {
        callback(key.data(), value);
    }
}

JNTDecoder JNTDocumentFetchValue(DecoderPointer decoder, const char *key) {
    auto child = decoder->element.at_key(key);
    if (child.error()) {
        JNTHandleMemberDoesNotExist(decoder, key);
    }
    return JNTCreateDecoder(child.value(), decoder->context);
}

bool JNTDocumentValueIsDictionary(DecoderPointer decoder) {
    return decoder->element.is<dom::object>();
}

bool JNTDocumentValueIsArray(DecoderPointer decoder) {
    return decoder->element.is<dom::array>();
}

bool JNTDocumentValueIsU64(DecoderPointer decoder) {
    return decoder->element.is<uint64_t>();
}

bool JNTDocumentValueIsI64(DecoderPointer decoder) {
    return decoder->element.is<int64_t>();
}

bool JNTDocumentValueIsDouble(DecoderPointer decoder) {
    return decoder->element.is<double>();
}

bool JNTIsNumericCharacter(char c) {
    return c == 'e' || c == 'E' || c == '-' || c == '.' || isnumber(c);
}

const char *JNTDocumentDecode__DecimalString(DecoderPointer decoder, int32_t *outLength) {
    abort();
    /**outLength = 0; // Make sure it doesn't get left uninitialized
    // todo: use uint64_t everywhere here if we ever support > 4GB files
    uint32_t location = (uint32_t)decoder->iterator.get_tape_location();
    uint32_t offset = decoder->context->parser.offsetForLocation(location);
    const char *dataStart = decoder->context->originalString;
    const char *dataEnd = dataStart + decoder->context->originalStringLength;
    const char *string = dataStart + offset;
    if (string >= dataEnd) {
        return NULL;
    }
    int32_t length = 0;
    // simdjson has already done validation on the numbers, so just try to find the end of the number.
    // we could also use the structural character idxs, probably
    while (JNTIsNumericCharacter(string[length]) && string + length < dataEnd) {
        length++;
    }
    *outLength = length;
    return string;*/
}

#define DECODE(A, B) DECODE_NAMED(A, B, A)

#define DECODE_NAMED(A, B, C) \
A JNTDocumentDecode__##C(DecoderPointer decoder) { \
    return JNTDocumentDecode<A, B>(decoder); \
}
ENUMERATE(DECODE);
