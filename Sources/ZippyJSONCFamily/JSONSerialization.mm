//Copyright (c) 2018 Michael Eisel. All rights reserved.

// NOTE: ARC is disabled for this file

#import "simdjson.h"
#import "JSONSerialization_Private.h"
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

// typedef simdjson::Iterator Iterator;
/*struct wrap {
  Iterator *iterator;
};*/

typedef simdjson::ParsedJson::iterator Iterator;

typedef struct {
    char *string;
    size_t capacity;
} JNTString;

static inline char JNTStringPop(char **string) {
    char c = **string;
    (*string)++;
    return c;
}

static inline void JNTStringPush(char **string, char c) {
    **string = c;
    (*string)++;
}

static __thread JNTDecodingError tError = {0};
static __thread JNTString tSnakeCaseBuffer = {0};

static __thread char *tPosInfString;
static __thread char *tNegInfString;
static __thread char *tNanString;

static const char *JNTStringForType(uint8_t type) {
    switch (type) {
        case 'n':
            return "null";
        case 't':
        case 'f':
            return "Bool";
        case '{':
            return "Dictionary";
        case '[':
            return "Array";
        case '"':
            return "String";
        case 'd':
        case 'l':
            return "Number";
    }
    return "?";
}

static inline void JNTSetError(const char *description, JNTDecodingErrorType type, Iterator *iterator, const char *key) {
    if (tError.type != JNTDecodingErrorTypeNone) {
        return;
    }
    Iterator *value = iterator ? new Iterator(*iterator) : NULL;
    if (key) {
        key = strdup(key);
    }
    tError = {
        .description = description,
        .type = type,
        .value = value,
        .key = key,
    };
}

static void JNTHandleJSONParsingFailed(int res) {
    char *description = nullptr;
    asprintf(&description, "The given data was not valid JSON. Error: %s", simdjson::errorMsg(res).c_str());
    JNTSetError(description, JNTDecodingErrorTypeJSONParsingFailed, NULL, NULL);
}

static void JNTHandleWrongType(Iterator *iterator, uint8_t type, const char *expectedType) {
    JNTDecodingErrorType errorType = type == 'n' ? JNTDecodingErrorTypeValueDoesNotExist : JNTDecodingErrorTypeWrongType;
    char *description = nullptr;
    asprintf(&description, "Expected %s value but found %s instead.", expectedType, JNTStringForType(type));
    JNTSetError(description, errorType, iterator, NULL);
}

static void JNTHandleMemberDoesNotExist(Iterator *iterator, const char *key) {
    char *description = nullptr;
    asprintf(&description, "No value associated with %s.", key);
    JNTSetError(description, JNTDecodingErrorTypeKeyDoesNotExist, iterator, key);
}

template <typename T>
static void JNTHandleNumberDoesNotFit(Iterator *iterator, T number, const char *type) {
    char *description = nullptr;
    NS_VALID_UNTIL_END_OF_SCOPE NSString *string = [@(number) description];
    asprintf(&description, "Parsed JSON number %s does not fit.", string.UTF8String); //, type);
    JNTSetError(description, JNTDecodingErrorTypeNumberDoesNotFit, iterator, NULL);
}

static void JNTStringGrow(JNTString *string, size_t newSize) {
    string->capacity = newSize;
    string->string = (char *)realloc((void *)string->string, newSize);
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

JNTDecodingError *JNTError() {
    return &tError;
}

static std::mutex sEmptyDictionaryMutex;
static ParsedJson *sEmptyDictionaryJson;
static __thread Iterator *tEmptyDictionaryIterator;
// Unless the lib ever supports custom key decoding, it will never try to lookup an empty string as a key
static const char kEmptyDictionaryString[] = "{\"\": 0}";
static const char kEmptyDictionaryStringLength = sizeof(kEmptyDictionaryString) - 1;

IteratorPointer JNTEmptyDictionaryIterator() {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sEmptyDictionaryJson = new ParsedJson;
        bool success = sEmptyDictionaryJson->allocateCapacity(kEmptyDictionaryStringLength);
        assert(success);
        json_parse(kEmptyDictionaryString, kEmptyDictionaryStringLength, *sEmptyDictionaryJson);
    });
    if (!tEmptyDictionaryIterator) {
        tEmptyDictionaryIterator = new Iterator(*sEmptyDictionaryJson);
        tEmptyDictionaryIterator->down();
    }
    return tEmptyDictionaryIterator;
}

static inline uint32_t JNTReplaceSnakeWithCamel(char *string) {
    char *end = string + strlen(string);
    char *currString = string;
    JNTStringGrow(&tSnakeCaseBuffer, end - string + 1);
    char *output = tSnakeCaseBuffer.string;
    char *currOutput = output;
    while (currString < end) {
        if (*currString != '_') {
            break;
        }
        JNTStringPush(&currOutput, '_');
        currString++;
    }
    if (currString == end) {
        return end - string;
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
        JNTStringPush(&currOutput, JNTToUpper(first));
        while (currString < end && *currString != '_') {
            char c = JNTStringPop(&currString);
            JNTStringPush(&currOutput, JNTToLower(c));
        }
        while (currString < end && *currString == '_') {
            didHitUnderscore = true;
            currString++;
        }
    }
    if (!didHitUnderscore) {
        return (uint32_t)(originalEnd - string);
    }
    output[leadingUnderscoreCount] = JNTToLower(output[leadingUnderscoreCount]); // If the first got capitalized
    for (NSInteger i = 0; i < originalEnd - end; i++) {
        JNTStringPush(&currOutput, '_');
    }
    JNTStringPush(&currOutput, '\0');
    memcpy(string, output, currOutput - output);
    return (uint32_t)(currOutput - output - 1);
}

void JNTConvertSnakeToCamel(IteratorPointer iterator) {
    do {
        if (!iterator->is_string()) {
            return;
        }
        uint32_t newLength = JNTReplaceSnakeWithCamel((char *)iterator->get_string());
        iterator->set_string_length(newLength);
        iterator->move_to_value();
    } while (iterator->next());
}

static inline char JNTChecker(const char *s) {
    char has = '\0';
    while (*s != '\0') {
        has |= *s;
        s++;
    }
    return has;
}

static inline char JNTCheckHelper(Iterator& i) {
    char has = '\0';
    if (i.is_object()) {
        if (!i.down()) {
            return has;
        }
        do {
            has |= JNTChecker(i.get_string());
            i.move_to_value();
            if (i.is_object_or_array()) {
                has |= JNTCheckHelper(i);
            }
        } while (i.next());
    } else if (i.is_array()) {
        if (!i.down()) {
            return has;
        }
        do {
            if (i.is_string()) {
                has |= JNTChecker(i.get_string());
            } else if (i.is_object_or_array()) {
                has |= JNTCheckHelper(i);
            }
        } while (i.next());
    }
    return has;
}

// Check if there are any non-ASCII chars in the dictionary keys
static inline bool JNTCheck(Iterator i) {
    return (JNTCheckHelper(i) & 0x80) != '\0';
}

static __thread ParsedJson *doc = NULL;
static __thread std::deque<Iterator> *tIterators;

IteratorPointer JNTDocumentFromJSON(const void *data, NSInteger length, bool convertCase, const char * *retryReason, bool fullPrecisionFloatParsing) {
    doc = new ParsedJson;
    doc->full_precision_float_parsing = fullPrecisionFloatParsing;
    bool success = doc->allocateCapacity(length); // 0 length?
    assert(success);
    tIterators = new std::deque<Iterator>();
    const int res = json_parse((const char *)data, length, *doc); // todo: handle error code
    if (res != 0) {
        if (res != NUMBER_ERROR) { // retry number errors
            JNTHandleJSONParsingFailed(res);
        } else {
            *retryReason = "A number was too large (couldn't fit in a 64-bit signed integer)";
        }
        return NULL;
    }
    Iterator iterator = Iterator(*doc); // todo: is this deallocated?
    if (JNTCheck(iterator)) {
        *retryReason = "One or more keys had non-ASCII characters";
        return NULL;
    } else {
        tIterators->push_back(iterator);
        return &(tIterators->back());
    }
}

void JNTReleaseDocument() {
    if (tError.description != NULL) {
        free((void *)tError.description);
    }
    if (tError.value != NULL) {
        delete ((Iterator *)tError.value);
    }
    if (tError.key != NULL) {
        free((void *)tError.key);
    }
    tError = {0};
    if (tPosInfString) {
        free(tPosInfString);
        free(tNegInfString);
        free(tNanString);
        tPosInfString = tNegInfString = tNanString = NULL;
    }
    delete (ParsedJson *)doc;
    doc = NULL;
    delete tIterators;
    tIterators = NULL;
    delete tEmptyDictionaryIterator;
    tEmptyDictionaryIterator = NULL;
    // memset(tPreviousLocation, 0, sizeof(tPreviousLocation));
}
// todo: all thread-locals get reset here?

BOOL JNTDocumentContains(IteratorPointer iterator, const char *key) {
    iterator->prev_string();
    return iterator->search_for_key(key, strlen(key));
}

namespace TypeChecker {
    bool Double(Iterator *value) {
        return value->is_double();
    }
    bool UInt64(Iterator *value) {
        return value->is_integer();
    }
    bool Int64(Iterator *value) {
        return value->is_integer();
    }
    bool String(Iterator *value) {
        return value->is_string();
    }

    bool Bool(Iterator *value) {
        return value->is_true() || value->is_false();
    }

}

namespace Converter {
    double Double(Iterator *value) {
        return value->get_double();
    }
    uint64_t UInt64(Iterator *value) {
        return value->get_integer();
    }
    int64_t Int64(Iterator *value) {
        return value->get_integer();
    }
    const char *String(Iterator *value) {
        return value->get_string();
    }
    bool Bool(Iterator *value) {
        return value->is_true();
    }
}

template <typename T, typename U, bool (*TypeCheck)(Iterator *), U (*Convert)(Iterator *)>
static inline T JNTDocumentDecode(IteratorPointer iterator) {
    if (unlikely(!TypeCheck(iterator))) {
        JNTHandleWrongType(iterator, iterator->get_type(), typeid(T).name());
        return 0;
    }
    U number = Convert(iterator);
    T result = (T)number;
    if (unlikely(number != result)) {
        JNTHandleNumberDoesNotFit(iterator, number, typeid(T).name());
        return 0;
    }
    return result;
}

void JNTDocumentNextArrayElement(IteratorPointer iterator, bool *isAtEnd) {
    *isAtEnd = !iterator->next();
}

BOOL JNTDocumentDecodeNil(IteratorPointer iterator) {
    return iterator->is_null();
}

static __thread bool tThreadLocked = false;

bool JNTAcquireThreadLock() {
    bool threadWasLocked = tThreadLocked;
    tThreadLocked = true;
    return !threadWasLocked;
}

void JNTReleaseThreadLock() {
    tThreadLocked = false;
}

void JNTUpdateFloatingPointStrings(const char *posInfString, const char *negInfString, const char *nanString) {
    asprintf(&tPosInfString, "%s", posInfString);
    asprintf(&tNegInfString, "%s", negInfString);
    asprintf(&tNanString, "%s", nanString);
}

double JNTDocumentDecode__Double(IteratorPointer iterator) {
    if (TypeChecker::Double(iterator)) {
        return Converter::Double(iterator);
    } else if (iterator->is_integer()){
        return (double)iterator->get_integer();
    } else {
        if (iterator->is_string()) {
            const char *string = iterator->get_string();
            if (strcmp(string, tPosInfString) == 0) {
                return INFINITY;
            } else if (strcmp(string, tNegInfString) == 0) {
                return -INFINITY;
            } else if (strcmp(string, tNanString) == 0) {
                return NAN;
            }
        }
        JNTHandleWrongType(iterator, iterator->get_type(), "double/float");
        return 0;
    }
}

float JNTDocumentDecode__Float(IteratorPointer iterator) {
    return (float)JNTDocumentDecode__Double(iterator);
}

static bool JNTIteratorsEqual(Iterator *i1, Iterator *i2) {
    return i1->get_tape_location() == i2->get_tape_location();
}

NSMutableArray <id> *JNTDocumentCodingPathHelper(Iterator iterator, Iterator *targetIterator) {
    if (iterator.is_array()) {
        if (iterator.down()) {
            NSInteger i = 0;
            do {
                if (JNTIteratorsEqual(&iterator, targetIterator)) {
                    return [@[@(i)] mutableCopy];
                } else if (iterator.is_object_or_array()) {
                    NSMutableArray *codingPath = JNTDocumentCodingPathHelper(iterator, targetIterator);
                    if (codingPath) {
                        [codingPath insertObject:@(i) atIndex:0];
                        return codingPath;
                    }
                }
            } while (iterator.next());
        }
    } else if (iterator.is_object()) {
        if (iterator.down()) {
            do {
                const char *key = iterator.get_string();
                if (JNTIteratorsEqual(&iterator, targetIterator)) {
                    return [@[@(key)] mutableCopy];
                }
                iterator.move_to_value();
                if (JNTIteratorsEqual(&iterator, targetIterator)) {
                    return [@[@(key)] mutableCopy];
                } else if (iterator.is_object_or_array()) {
                    NSMutableArray *codingPath = JNTDocumentCodingPathHelper(iterator, targetIterator);
                    if (codingPath) {
                        [codingPath insertObject:@(key) atIndex:0];
                        return codingPath;
                    }
                }
            } while (iterator.next());
        }
    }
    return [@[] mutableCopy];
}

NSArray <id> *JNTDocumentCodingPath(IteratorPointer targetIterator) {
    Iterator iterator = Iterator(*doc); // todo: copy constructor? deallocation of iterator?
    if (JNTIteratorsEqual(&iterator, targetIterator)) {
        return @[];
    }
    return JNTDocumentCodingPathHelper(iterator, targetIterator) ?: @[];
}

NSArray <NSString *> *JNTDocumentAllKeys(IteratorPointer iterator) {
    if (iterator->is_object()) {
        return @[];
    }
    NSMutableArray <NSString *>*keys = [NSMutableArray array];
    iterator->to_start_scope();
    do {
        if (!iterator->is_string()) {
            break;
        }
        [keys addObject:@(iterator->get_string())];
        iterator->move_to_value();
    } while (iterator->next());
    return [keys copy];
}

void JNTDocumentForAllKeyValuePairs(IteratorPointer iteratorOriginal, void (^callback)(const char *key, IteratorPointer iterator)) {
    // Make a copy of the iterator
    Iterator iterator = *(iteratorOriginal);
    if (iterator.get_scope_type() != '{') {
        return;
    }
    if (!iterator.down()) {
        return;
    }
    do {
        const char *key = iterator.get_string();
        iterator.move_to_value();
        callback(key, &iterator);
    } while (iterator.next());
}

IteratorPointer JNTDocumentEnterStructureAndReturnCopy(IteratorPointer iterator) {
    tIterators->emplace_back(*(iterator));
    if (tIterators->back().down()) {
        return &(tIterators->back());
    } else {
        tIterators->pop_back(); // todo: why pop_back here?
        return NULL;
    }
}

__attribute__((always_inline)) IteratorPointer JNTDocumentFetchValue(IteratorPointer iterator, const char *key) {
    iterator->prev_string();
    if (!iterator->search_for_key(key, strlen(key))) {
        JNTHandleMemberDoesNotExist(iterator, key);
    }
    return iterator;
}
// todo: case where iterator starts searching at end of scope, ie '}'

bool JNTDocumentValueIsDictionary(IteratorPointer iterator) {
    return iterator->is_object();
}

bool JNTDocumentValueIsArray(IteratorPointer iterator) {
    return iterator->is_array();
}

#define DECODE(A, B, C, D) DECODE_NAMED(A, B, C, D, A)

#define DECODE_NAMED(A, B, C, D, E) \
A JNTDocumentDecode__##E(IteratorPointer iterator) { \
    return JNTDocumentDecode<A, B, TypeChecker::C, Converter::D>(iterator); \
}
ENUMERATE(DECODE);

// public private visibility
// todo: simdjson stable version and not debug?
// todo: swift 5.0?
// disable testability on release, asan, memory leaks, tsan
// todo: disable armv7 on release
