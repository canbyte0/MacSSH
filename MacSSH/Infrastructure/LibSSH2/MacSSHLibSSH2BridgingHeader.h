#ifndef MacSSH_LIBSSH2_BRIDGING_HEADER
#define MacSSH_LIBSSH2_BRIDGING_HEADER

// Phase 5：引入 libssh2 C API。
// 依赖来源与版本锁定见 Scripts/build-dependencies.sh 与 ThirdParty/MANIFEST.txt。

// Phase 5.1：引入 build-generated 依赖身份（exact commit / 版本 / 静态库 SHA256），
// 由 Scripts/build-dependencies.sh 生成，Tests/SSH/DependencyIdentityTests.swift 断言，
// 防止 App 实际链接的静态库与文档 pin 不一致。
#include <MacSSHDependencyIdentity.h>

#include <libssh2.h>

#endif /* MacSSH_LIBSSH2_BRIDGING_HEADER */
