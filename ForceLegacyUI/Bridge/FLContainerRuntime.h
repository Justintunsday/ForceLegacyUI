// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
#include <stdbool.h>
#include <xpc/xpc.h>
NS_ASSUME_NONNULL_BEGIN

/// Private transport boundary. Production uses resolved OS functions; CLI tests inject responses.
typedef struct {
    void * _Nullable (* _Nullable create)(void);
    void (* _Nullable kind)(void *, uint64_t);
    void (* _Nullable identifiers)(void *, xpc_object_t);
    void (* _Nullable groups)(void *, xpc_object_t);
    void (* _Nullable flags)(void *, uint64_t);
    void (* _Nullable part)(void *, uint64_t);
    void (* _Nullable domain)(void *, const char *);
    void * _Nullable (* _Nullable result)(void *);
    const char * _Nullable (* _Nullable path)(void *);
    bool (* _Nullable iterate)(void *, bool (^callback)(void *));
    const char * _Nullable (* _Nullable identifier)(void *);
    char * _Nullable (* _Nullable token)(void *);
    void * _Nullable (* _Nullable duplicate)(void *);
    bool (* _Nullable activate)(void *, bool);
    void (* _Nullable freeObject)(void *);
    void (* _Nullable dispose)(void *);
    int64_t (* _Nullable consume)(const char *);
    int (* _Nullable release)(int64_t);
    void * _Nullable (* _Nullable failure)(void *);
    const char * _Nullable (* _Nullable message)(void *);
    int (* _Nullable posix)(void *);
    BOOL (* _Nullable readableDirectory)(const char *, int * _Nullable);
} FLContainerRuntime;

typedef void * _Nullable (^FLContainerSymbolLookup)(const char *name);

#if defined(FL_CONTAINER_TESTING)
@class FLLSDContainerLease;
FOUNDATION_EXPORT FLContainerRuntime FLTestResolveContainerRuntime(FLContainerSymbolLookup lookup);
FOUNDATION_EXPORT FLLSDContainerLease * _Nullable FLTestOpenLSDLease(uint64_t kind, const FLContainerRuntime * _Nonnull runtime, NSMutableString * _Nonnull log);
FOUNDATION_EXPORT NSArray<NSDictionary<NSString *, id> *> *FLTestMHAAppDataCatalog(const FLContainerRuntime *runtime, NSUInteger limit, NSMutableString *log);
#endif
NS_ASSUME_NONNULL_END
