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

bool JNTHasVectorExtensions() {
#ifdef __SSE4_2__
  return true;
#else
  return false;
#endif
}

struct JNTContext;

struct JNTDecoder {
    dom::element element;
    JNTContext *context;
};

struct JNTDecodingError {
    std::string description = "";
    JNTDecodingErrorType type = JNTDecodingErrorTypeNone;
    JNTDecoder value = JNTDecoder();
    std::string key = "";
    JNTDecodingError() {
    }
    JNTDecodingError(std::string description, JNTDecodingErrorType type, JNTDecoder value, std::string key) : description(description), type(type), value(value), key(key) {
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
    BOOL stringsForFloats;

    const char *originalString;
    uint32_t originalStringLength;

    JNTContext(const char *originalString, uint32_t originalStringLength, std::string posInfString, std::string negInfString, std::string nanString, BOOL stringsForFloats) : originalString(originalString), originalStringLength(originalStringLength), posInfString(posInfString), negInfString(negInfString), nanString(nanString), stringsForFloats(stringsForFloats) {
    }
};

static_assert(sizeof(JNTDecoder[2]) == sizeof(JNTDecoderStorage[2]), "");
static_assert(sizeof(JNTElementStorage) == sizeof(dom::object::iterator), "");
static_assert(sizeof(JNTElementStorage) == sizeof(dom::array::iterator), "");
static_assert(sizeof(JNTElementStorage[2]) == sizeof(dom::array::iterator[2]), "");
static_assert(alignof(JNTDecoder) == alignof(JNTDecoderStorage), "");
static_assert(alignof(JNTDecoder[2]) == alignof(JNTDecoderStorage[2]), "");
static_assert(alignof(JNTElementStorage) == alignof(dom::object::iterator), "");
static_assert(alignof(JNTElementStorage) == alignof(dom::array::iterator), "");
static_assert(alignof(JNTElementStorage[2]) == alignof(dom::array::iterator[2]), "");
static_assert(std::is_trivially_copyable<JNTDecoder>(), "");
static_assert(std::is_trivially_copyable<dom::element>(), "");
static_assert(std::is_trivially_copyable<dom::array::iterator>());
static_assert(std::is_trivially_copyable<dom::object::iterator>());

static inline JNTDecoder JNTCreateDecoder(dom::element element, JNTContext *context) {
    JNTDecoder decoder;
    decoder.element = element;
    decoder.context = context;
    return decoder;
}

static inline JNTDecoder JNTDecoderDefault() {
    dom::element defaultElement;
    return JNTCreateDecoder(defaultElement, NULL);
}

void JNTClearError(ContextPointer context) {
    context->error = JNTDecodingError();
}

bool JNTErrorDidOccur(ContextPointer context) {
    return context->error.type != JNTDecodingErrorTypeNone;
}

bool JNTDocumentErrorDidOccur(JNTDecoder decoder) {
    return JNTErrorDidOccur(decoder.context);
}

void JNTProcessError(ContextPointer context, void (^block)(const char *description, JNTDecodingErrorType type, JNTDecoder value, const char *key)) {
    JNTDecodingError &error = context->error;
    block(error.description.c_str(), error.type, error.value, error.key.c_str());
}

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

static inline void JNTSetError(std::string description, JNTDecodingErrorType type, JNTContext *context, JNTDecoder value, std::string key) {
    if (context->error.type != JNTDecodingErrorTypeNone) {
        return;
    }
    context->error = JNTDecodingError(description, type, value, key);
}

static void JNTHandleWrongType(JNTDecoder decoder, dom::element_type type, const char *expectedType) {
    JNTDecodingErrorType errorType = type == dom::element_type::NULL_VALUE ? JNTDecodingErrorTypeValueDoesNotExist : JNTDecodingErrorTypeWrongType;
    std::ostringstream oss;
    oss << "Expected to decode " << expectedType << " but found " << JNTStringForType(type) << " instead.";
    JNTSetError(oss.str(), errorType, decoder.context, decoder, "");
}

static void JNTHandleMemberDoesNotExist(JNTDecoder decoder, const char *key) {
    std::ostringstream oss;
    oss << "No value associated with " << key << ".";
    JNTSetError(oss.str(), JNTDecodingErrorTypeKeyDoesNotExist, decoder.context, decoder, key);
}

template <typename T>
static void JNTHandleNumberDoesNotFit(JNTDecoder decoder, T number, const char *type) {
    NS_VALID_UNTIL_END_OF_SCOPE NSString *string = [@(number) description];
    std::ostringstream oss;
    oss << "Parsed JSON number " << string.UTF8String << " does not fit.";
    std::string description = oss.str();
    JNTSetError(description, JNTDecodingErrorTypeNumberDoesNotFit, decoder.context, decoder, "");
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

void JNTConvertSnakeToCamel(JNTDecoder decoder) {
    dom::object object = decoder.element;
    for (auto it = object.begin(); it != object.end(); ++it) {
        char *string = (char *)it.key_c_str();
        uint32_t length = JNTReplaceSnakeWithCamel(decoder.context->snakeCaseBuffer, string);
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

static inline char JNTCheckHelper(const dom::element &element) {
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
                has |= JNTCheckHelper(member);
            }
        }
    }
    return has;
}

// Check if there are any non-ASCII chars in the dictionary keys
static inline bool JNTCheck(dom::element &element) {
    return (JNTCheckHelper(element) & 0x80) != '\0';
}

ContextPointer JNTCreateContext(const char *originalString, uint32_t originalStringLength, const char *negInfString, const char *posInfString, const char *nanString, BOOL stringsForFloats) {
    return new JNTContext(originalString, originalStringLength, std::string(posInfString), std::string(negInfString), std::string(nanString), stringsForFloats);
}

static const uint64_t kDataLimit = (1ULL << 32) - 1;

JNTDecoder JNTDocumentFromJSON(ContextPointer context, const void *data, NSInteger length, bool convertCase, const char * *retryReason, bool *success) {
    *success = false;
    if (length > kDataLimit) {
        *retryReason = "The length of the JSON data is too long (see kDataLimit for the max)";
        return JNTDecoderDefault();
    }
    simdjson::padded_string ps = simdjson::padded_string((char *)data, length);
    auto result = context->parser.parse(ps);
    if (result.error()) {
        *retryReason = "Either the JSON is malformed, e.g. passing a number as the root object, or an integer was too large (couldn't fit in a 64-bit unsigned integer)";
        return JNTDecoderDefault();
    }
    context->root = result.value();
    if (JNTCheck(context->root)) {
        *retryReason = "One or more keys had non-ASCII characters";
        return JNTDecoderDefault();
    } else {
        *success = true;
        JNTDecoder decoder;
        decoder.element = context->root;
        decoder.context = context;
        return decoder;
    }
}

void JNTReleaseContext(JNTContext *context) {
    delete context;
}

static double JNTNumericValue(dom::element &element) {
    if (element.is<double>()) {
        return element.get<double>().value();
    } else if (element.is<int64_t>()) {
        return element.get<int64_t>().value();
    } else if (element.is<uint64_t>()) {
        return element.get<uint64_t>().value();
    }
    return 0;
}

template <typename T, typename U>
inline T JNTDocumentDecode(JNTDecoder decoder, dom::element element) {
    simdjson_result<U> value = element.get<U>();
    if (unlikely(value.error())) {
        BOOL elementIsNumeric = element.is<double>() || element.is<int64_t>() || element.is<uint64_t>();
        if (std::is_integral<T>() && std::is_integral<U>() && elementIsNumeric) {
            // If we asked for a number type, and simdjson complained strictly because it had a number of a type that
            // couldn't be losslessly casted to the one we asked for, then the error is that the number doesn't fit
            JNTHandleNumberDoesNotFit(decoder, JNTNumericValue(element), typeid(T).name());
            return (T)0;
        }
        JNTHandleWrongType(decoder, element.type(), typeid(T).name());
        return (T)0;
    }
    U trueValue = value.value();
    T returnValue = (T)trueValue;
    if (trueValue != returnValue) {
        JNTHandleNumberDoesNotFit(decoder, trueValue, typeid(T).name());
        return 0;
    }
    return returnValue;
}

template <>
inline double JNTDocumentDecode<double, double>(JNTDecoder decoder, dom::element element) {
    if (element.is<double>()) {
        return element;
    } else {
        if (element.is<std::string_view>() && decoder.context->stringsForFloats) {
            std::string_view string = element;
            if (string == decoder.context->posInfString) {
                return INFINITY;
            } else if (string == decoder.context->negInfString) {
                return -INFINITY;
            } else if (string == decoder.context->nanString) {
                return NAN;
            }
        }
        JNTHandleWrongType(decoder, element.type(), "double/float");
        return 0;
    }
}

template <>
inline float JNTDocumentDecode<float, double>(JNTDecoder decoder, dom::element element) {
    return (float)JNTDocumentDecode<double, double>(decoder, element);
}

// Pre-condition: element is an array type
NSInteger JNTDocumentGetArrayCount(JNTDecoder decoder) {
    NSInteger count = 0;
    dom::array array = decoder.element;
    for (auto it = array.begin(); it != array.end(); ++it) {
        count++;
    }
    return count;
}

void JNTAdvanceIterator(JNTArrayIterator *iterator, JNTDecoder root) {
    dom::array array = root.element;
    assert(*iterator != array.end());
    ++(*iterator);
}

JNTDecoder JNTDecoderFromIterator(JNTArrayIterator *iterator, JNTDecoder root) {
    dom::array array = root.element;
    assert(*iterator != array.end());
    return JNTCreateDecoder(**iterator, root.context);
}

bool JNTDocumentDecodeNil(JNTDecoder decoder) {
    return decoder.element.is_null();
}

static bool JNTIteratorsEqual(dom::element &e1, dom::element &e2) {
    const auto ptr1 = (simdjson::internal::tape_ref *)&e1;
    auto index1 = ptr1->json_index;
    const auto ptr2 = (simdjson::internal::tape_ref *)&e2;
    auto index2 = ptr2->json_index;
    assert(ptr1->doc == ptr2->doc);
    return index1 == index2;
}

JNTDictionaryIterator JNTDocumentGetDictionaryIterator(JNTDecoder decoder) {
    dom::object object = decoder.element;
    return object.begin();
}

JNTArrayIterator JNTDocumentGetIterator(JNTDecoder decoder) {
    dom::array array = decoder.element;
    return array.begin();
}

NSMutableArray <id> *JNTDocumentCodingPathHelper(dom::element &element, dom::element &targetElement) {
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
            if (JNTIteratorsEqual(value, targetElement)) {
                return [@[@(std::string(key).c_str())] mutableCopy];
            }
            if (JNTIteratorsEqual(value, targetElement)) {
                return [@[@(std::string(key).c_str())] mutableCopy];
            } else if (value.is<dom::array>() || value.is<dom::object>()) {
                NSMutableArray *codingPath = JNTDocumentCodingPathHelper(value, targetElement);
                if (codingPath) {
                    [codingPath insertObject:@(std::string(key).c_str()) atIndex:0];
                    return codingPath;
                }
            }
        }
    }
    return nil;
}

NSArray <id> *JNTDocumentCodingPath(JNTDecoder targetDecoder) {
    dom::element &element = targetDecoder.context->root;
    if (JNTIteratorsEqual(element, targetDecoder.element)) {
        return @[];
    }
    NSMutableArray *array = JNTDocumentCodingPathHelper(element, targetDecoder.element);
    return array ? [array copy] : @[];
}

NSArray <NSString *> *JNTDocumentAllKeys(JNTDecoder decoder) {
    NSMutableArray <NSString *>*keys = [NSMutableArray array];
    dom::object object = decoder.element;
    for (auto [key, value] : object) {
        const char *cString = key.data();
        [keys addObject:@(cString)];
    }
    return [keys copy];
}

void JNTDocumentForAllKeyValuePairs(JNTDecoder decoderOriginal, void (^callback)(const char *key, JNTDecoder element)) {
    const auto &object = decoderOriginal.element.get<dom::object>();
    if (object.error()) {
        JNTHandleWrongType(decoderOriginal, decoderOriginal.element.type(), "dictionary");
        return;
    }
    for (auto [key, value] : object) {
        JNTDecoder decoder = JNTCreateDecoder(value, decoderOriginal.context);
        callback(key.data(), decoder);
    }
}

simdjson_result<dom::element> JNTDocumentFindValue(JNTDecoder decoder, const char *cKey, JNTDictionaryIterator *iteratorPtr) {
    auto iterator = *iteratorPtr;
    std::string_view key = cKey;
    const auto searchStart = iterator;
    const dom::object &object = decoder.element;
    const auto &end = object.end();
    dom::element child;
    bool found = false;
    while (iterator != end) {
        if (key == iterator.key()) {
            child = iterator.value();
            found = true;
            break;
        }
        ++iterator;
    }
    if (!found) {
        iterator = object.begin();
        while (iterator != searchStart) {
            if (key == iterator.key()) {
                child = iterator.value();
                found = true;
                break;
            }
            ++iterator;
        }
    }
    if (!found) {
        return simdjson_result<dom::element>(NO_SUCH_FIELD);
    }
    *iteratorPtr = iterator;
    return simdjson_result<dom::element>(std::move(child));
}

bool JNTDocumentContains(JNTDecoder decoder, const char *key, JNTDictionaryIterator *iteratorPtr) {
    const auto &result = JNTDocumentFindValue(decoder, key, iteratorPtr);
    return result.error() == SUCCESS;
}

JNTDecoder JNTDocumentFetchValue(JNTDecoder decoder, const char *key, JNTDictionaryIterator *iteratorPtr) {
    const auto &result = JNTDocumentFindValue(decoder, key, iteratorPtr);
    if (result.error() != SUCCESS) {
        JNTHandleMemberDoesNotExist(decoder, key);
        return decoder;
    }
    return JNTCreateDecoder(result.first, decoder.context);
}

bool JNTDocumentValueIsDictionary(JNTDecoder decoder) {
    return decoder.element.is<dom::object>();
}

bool JNTDocumentValueIsArray(JNTDecoder decoder) {
    return decoder.element.is<dom::array>();
}

bool JNTDocumentValueIsInteger(JNTDecoder decoder) {
    return decoder.element.is<int64_t>() || decoder.element.is<uint64_t>();
}

bool JNTDocumentValueIsDouble(JNTDecoder decoder) {
    return decoder.element.is<double>();
}

bool JNTIsNumericCharacter(char c) {
    return c == 'e' || c == 'E' || c == '-' || c == '.' || isnumber(c);
}

ContextPointer JNTGetContext(JNTDecoder decoder) {
    return decoder.context;
}

const char *JNTDocumentDecode__DecimalString(JNTDecoder decoder, int32_t *outLength) {
    *outLength = 0; // Making sure it doesn't get left uninitialized
    // todo: use uint64_t everywhere here if we ever support > 4GB files
    uint64_t offset = decoder.context->parser.offset_for_element(decoder.element);
    const char *dataStart = decoder.context->originalString;
    const char *dataEnd = dataStart + decoder.context->originalStringLength;
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
    return string;
}

#define DECODE(A, B) DECODE_NAMED(A, B, A)

#define DECODE_NAMED(A, B, C) \
A JNTDocumentDecode__##C(JNTDecoder decoder) { \
    return JNTDocumentDecode<A, B>(decoder, decoder.element); \
}

ENUMERATE(DECODE);
