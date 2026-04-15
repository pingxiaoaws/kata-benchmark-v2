# gVisor Syscall 兼容性参考文档

> 源码参考：[`pkg/sentry/syscalls/linux/linux64.go`](https://github.com/google/gvisor/blob/master/pkg/sentry/syscalls/linux/linux64.go)
>
> 官方文档：[AMD64](https://gvisor.dev/docs/user_guide/compatibility/linux/amd64/) | [ARM64](https://gvisor.dev/docs/user_guide/compatibility/linux/arm64/)

---

## 1. 总览统计

|                     | AMD64 | ARM64 |
| ------------------- | ----- | ----- |
| ✅ **完全实现**      | 222   | 185   |
| ⚠️ **部分实现**      | 52    | 52    |
| ❌ **未实现**        | 76    | 56    |
| **总计**            | 350   | 293   |

> ARM64 总数较少是因为 ARM64 Linux 设计时就移除了许多 x86 遗留 syscall（如 `open` → `openat`，`fork` → `clone`，`dup2` → `dup3` 等），只保留了现代变体。

---

## 2. 未实现 Syscall 的行为

当应用调用 gVisor Sentry **未实现**的 syscall 时：

```
应用程序
  │
  │  syscall(某个调用)
  ▼
┌──────────────────────────────────────┐
│  Sentry (gVisor 用户态内核)            │
│                                      │
│  switch(syscall_nr) {                │
│    case 已实现:   → Sentry 自己处理    │
│    case 部分实现: → 部分 flag 不支持    │
│    default:      → 返回 -ENOSYS      │
│  }                                   │
│                                      │
│  ┌──────────────────┐                │
│  │ 绝不 forward     │                │
│  │ 到宿主机内核      │                │
│  └──────────────────┘                │
└──────────────────────────────────────┘
          │ (只有 Sentry 自身需要时)
          │ 极少量 syscall（~20 个）
          ▼
    宿主机 Linux 内核
```

- **返回 `ENOSYS`**（Function not implemented），与真实 Linux 内核未编译某 syscall 时的行为一致
- **绝不转发到宿主机内核** — 这是 gVisor 安全模型的核心保证
- 大部分成熟应用会正确处理 `ENOSYS` 并做 fallback；少数应用可能直接崩溃或行为异常

---

## 3. AMD64 (x86_64) Syscall 详表

### 3.1 ✅ 完全实现 — 222 个

| # | Name | # | Name | # | Name |
|---|------|---|------|---|------|
| 0 | read | 1 | write | 2 | open |
| 3 | close | 4 | stat | 5 | fstat |
| 6 | lstat | 7 | poll | 8 | lseek |
| 9 | mmap | 10 | mprotect | 11 | munmap |
| 12 | brk | 13 | rt_sigaction | 14 | rt_sigprocmask |
| 15 | rt_sigreturn | 16 | ioctl | 17 | pread64 |
| 18 | pwrite64 | 19 | readv | 20 | writev |
| 21 | access | 22 | pipe | 23 | select |
| 24 | sched_yield | 25 | mremap | 32 | dup |
| 33 | dup2 | 34 | pause | 35 | nanosleep |
| 36 | getitimer | 37 | alarm | 38 | setitimer |
| 39 | getpid | 40 | sendfile | 41 | socket |
| 42 | connect | 43 | accept | 44 | sendto |
| 45 | recvfrom | 46 | sendmsg | 47 | recvmsg |
| 48 | shutdown | 49 | bind | 50 | listen |
| 51 | getsockname | 52 | getpeername | 53 | socketpair |
| 54 | setsockopt | 55 | getsockopt | 57 | fork |
| 58 | vfork | 59 | execve | 60 | exit |
| 61 | wait4 | 62 | kill | 63 | uname |
| 64 | semget | 66 | semctl | 67 | shmdt |
| 68 | msgget | 69 | msgsnd | 70 | msgrcv |
| 71 | msgctl | 72 | fcntl | 73 | flock |
| 74 | fsync | 75 | fdatasync | 76 | truncate |
| 77 | ftruncate | 78 | getdents | 79 | getcwd |
| 80 | chdir | 81 | fchdir | 82 | rename |
| 83 | mkdir | 84 | rmdir | 85 | creat |
| 86 | link | 87 | unlink | 88 | symlink |
| 89 | readlink | 90 | chmod | 91 | fchmod |
| 92 | chown | 93 | fchown | 94 | lchown |
| 95 | umask | 96 | gettimeofday | 97 | getrlimit |
| 100 | times | 102 | getuid | 104 | getgid |
| 105 | setuid | 106 | setgid | 107 | geteuid |
| 108 | getegid | 109 | setpgid | 110 | getppid |
| 111 | getpgrp | 112 | setsid | 113 | setreuid |
| 114 | setregid | 115 | getgroups | 116 | setgroups |
| 117 | setresuid | 118 | getresuid | 119 | setresgid |
| 120 | getresgid | 121 | getpgid | 124 | getsid |
| 125 | capget | 126 | capset | 127 | rt_sigpending |
| 128 | rt_sigtimedwait | 129 | rt_sigqueueinfo | 130 | rt_sigsuspend |
| 131 | sigaltstack | 132 | utime | 133 | mknod |
| 137 | statfs | 138 | fstatfs | 155 | pivot_root |
| 161 | chroot | 162 | sync | 165 | mount |
| 166 | umount2 | 170 | sethostname | 171 | setdomainname |
| 186 | gettid | 187 | readahead | 188 | setxattr |
| 189 | lsetxattr | 190 | fsetxattr | 191 | getxattr |
| 192 | lgetxattr | 193 | fgetxattr | 194 | listxattr |
| 195 | llistxattr | 196 | flistxattr | 197 | removexattr |
| 198 | lremovexattr | 199 | fremovexattr | 200 | tkill |
| 201 | time | 213 | epoll_create | 217 | getdents64 |
| 218 | set_tid_address | 219 | restart_syscall | 220 | semtimedop |
| 222 | timer_create | 223 | timer_settime | 224 | timer_gettime |
| 225 | timer_getoverrun | 226 | timer_delete | 227 | clock_settime |
| 228 | clock_gettime | 229 | clock_getres | 230 | clock_nanosleep |
| 231 | exit_group | 232 | epoll_wait | 233 | epoll_ctl |
| 234 | tgkill | 235 | utimes | 240 | mq_open |
| 241 | mq_unlink | 247 | waitid | 257 | openat |
| 258 | mkdirat | 259 | mknodat | 260 | fchownat |
| 261 | futimesat | 262 | newfstatat | 263 | unlinkat |
| 264 | renameat | 265 | linkat | 266 | symlinkat |
| 267 | readlinkat | 268 | fchmodat | 269 | faccessat |
| 270 | pselect6 | 271 | ppoll | 273 | set_robust_list |
| 274 | get_robust_list | 275 | splice | 276 | tee |
| 277 | sync_file_range | 280 | utimensat | 281 | epoll_pwait |
| 282 | signalfd | 283 | timerfd_create | 284 | eventfd |
| 286 | timerfd_settime | 287 | timerfd_gettime | 288 | accept4 |
| 289 | signalfd4 | 290 | eventfd2 | 291 | epoll_create1 |
| 292 | dup3 | 293 | pipe2 | 295 | preadv |
| 296 | pwritev | 297 | rt_tgsigqueueinfo | 299 | recvmmsg |
| 302 | prlimit64 | 306 | syncfs | 307 | sendmmsg |
| 308 | setns | 309 | getcpu | 310 | process_vm_readv |
| 311 | process_vm_writev | 316 | renameat2 | 317 | seccomp |
| 318 | getrandom | 319 | memfd_create | 322 | execveat |
| 332 | statx | 436 | close_range | 439 | faccessat2 |
| 441 | epoll_pwait2 | | | | |

### 3.2 ⚠️ 部分实现 — 52 个

| # | Name | # | Name | # | Name |
|---|------|---|------|---|------|
| 26 | msync | 27 | mincore | 28 | madvise |
| 29 | shmget | 30 | shmat | 31 | shmctl |
| 56 | clone | 65 | semop | 98 | getrusage |
| 99 | sysinfo | 101 | ptrace | 103 | syslog |
| 140 | getpriority | 141 | setpriority | 143 | sched_getparam |
| 144 | sched_setscheduler | 145 | sched_getscheduler | 146 | sched_get_priority_max |
| 147 | sched_get_priority_min | 149 | mlock | 150 | munlock |
| 151 | mlockall | 152 | munlockall | 157 | prctl |
| 158 | arch_prctl | 160 | setrlimit | 183 | afs_syscall |
| 202 | futex | 203 | sched_setaffinity | 204 | sched_getaffinity |
| 206 | io_setup | 207 | io_destroy | 208 | io_getevents |
| 209 | io_submit | 210 | io_cancel | 221 | fadvise64 |
| 237 | mbind | 238 | set_mempolicy | 239 | get_mempolicy |
| 250 | keyctl | 253 | inotify_init | 254 | inotify_add_watch |
| 255 | inotify_rm_watch | 272 | unshare | 285 | fallocate |
| 294 | inotify_init1 | 324 | membarrier | 325 | mlock2 |
| 327 | preadv2 | 328 | pwritev2 | 334 | rseq |
| 425 | io_uring_setup | 426 | io_uring_enter | 435 | clone3 |

**典型限制说明：**

| Syscall | 限制说明 |
|---------|---------|
| `clone` / `clone3` | 基本功能可用，部分 flag 组合不支持 |
| `futex` | 常用操作支持，部分高级操作（如 `FUTEX_LOCK_PI`）可能不全 |
| `prctl` | 常见子命令支持，冷门子命令返回 `EINVAL` |
| `ptrace` | 基本调试功能可用，部分请求不支持 |
| `madvise` / `msync` / `mincore` | 部分 advice 类型被忽略或不支持 |
| `mlock` / `mlockall` / `mlock2` | 接受调用但可能不真正锁定物理页 |
| `sched_setaffinity/getaffinity` | 基本可用，但 CPU 亲和性语义在虚拟环境下不同 |
| `inotify_*` | 基本文件监控可用，边缘情况可能不触发 |
| `io_uring_setup/enter` | 实验性支持，功能不完整 |
| `fallocate` | 基本功能可用，部分模式不支持 |

### 3.3 ❌ 未实现 — 76 个

| # | Name | # | Name | # | Name |
|---|------|---|------|---|------|
| 122 | setfsuid | 123 | setfsgid | 134 | uselib |
| 135 | personality | 136 | ustat | 139 | sysfs |
| 142 | sched_setparam | 148 | sched_rr_get_interval | 153 | vhangup |
| 154 | modify_ldt | 156 | sysctl | 159 | adjtimex |
| 163 | acct | 164 | settimeofday | 167 | swapon |
| 168 | swapoff | 169 | reboot | 172 | iopl |
| 173 | ioperm | 174 | create_module | 175 | init_module |
| 176 | delete_module | 177 | get_kernel_syms | 178 | query_module |
| 179 | quotactl | 180 | nfsservctl | 181 | getpmsg |
| 182 | putpmsg | 184 | tuxcall | 185 | security |
| 205 | set_thread_area | 211 | get_thread_area | 212 | lookup_dcookie |
| 214 | epoll_ctl_old | 215 | epoll_wait_old | 216 | remap_file_pages |
| 236 | vserver | 242 | mq_timedsend | 243 | mq_timedreceive |
| 244 | mq_notify | 245 | mq_getsetattr | 246 | kexec_load |
| 248 | add_key | 249 | request_key | 251 | ioprio_set |
| 252 | ioprio_get | 256 | migrate_pages | 278 | vmsplice |
| 279 | move_pages | 298 | perf_event_open | 300 | fanotify_init |
| 301 | fanotify_mark | 303 | name_to_handle_at | 304 | open_by_handle_at |
| 305 | clock_adjtime | 312 | kcmp | 313 | finit_module |
| 314 | sched_setattr | 315 | sched_getattr | 320 | kexec_file_load |
| 321 | bpf | 323 | userfaultfd | 326 | copy_file_range |
| 329 | pkey_mprotect | 330 | pkey_alloc | 331 | pkey_free |
| 333 | io_pgetevents | 424 | pidfd_send_signal | 427 | io_uring_register |
| 428 | open_tree | 429 | move_mount | 430 | fsopen |
| 431 | fsconfig | 432 | fsmount | 433 | fspick |
| 434 | pidfd_open | | | | |

---

## 4. ARM64 (aarch64) Syscall 详表

### 4.1 ✅ 完全实现 — 185 个

| # | Name | # | Name | # | Name |
|---|------|---|------|---|------|
| 5 | setxattr | 6 | lsetxattr | 7 | fsetxattr |
| 8 | getxattr | 9 | lgetxattr | 10 | fgetxattr |
| 11 | listxattr | 12 | llistxattr | 13 | flistxattr |
| 14 | removexattr | 15 | lremovexattr | 16 | fremovexattr |
| 17 | getcwd | 19 | eventfd2 | 20 | epoll_create1 |
| 21 | epoll_ctl | 22 | epoll_pwait | 23 | dup |
| 24 | dup3 | 25 | fcntl | 29 | ioctl |
| 32 | flock | 33 | mknodat | 34 | mkdirat |
| 35 | unlinkat | 36 | symlinkat | 37 | linkat |
| 38 | renameat | 39 | umount2 | 40 | mount |
| 41 | pivot_root | 43 | statfs | 44 | fstatfs |
| 45 | truncate | 46 | ftruncate | 48 | faccessat |
| 49 | chdir | 50 | fchdir | 51 | chroot |
| 52 | fchmod | 53 | fchmodat | 54 | fchownat |
| 55 | fchown | 56 | openat | 57 | close |
| 59 | pipe2 | 61 | getdents64 | 62 | lseek |
| 63 | read | 64 | write | 65 | readv |
| 66 | writev | 67 | pread64 | 68 | pwrite64 |
| 69 | preadv | 70 | pwritev | 71 | sendfile |
| 72 | pselect6 | 73 | ppoll | 74 | signalfd4 |
| 76 | splice | 77 | tee | 78 | readlinkat |
| 79 | newfstatat | 80 | fstat | 81 | sync |
| 82 | fsync | 83 | fdatasync | 84 | sync_file_range |
| 85 | timerfd_create | 86 | timerfd_settime | 87 | timerfd_gettime |
| 88 | utimensat | 90 | capget | 91 | capset |
| 93 | exit | 94 | exit_group | 95 | waitid |
| 96 | set_tid_address | 99 | set_robust_list | 100 | get_robust_list |
| 101 | nanosleep | 102 | getitimer | 103 | setitimer |
| 107 | timer_create | 108 | timer_gettime | 109 | timer_getoverrun |
| 110 | timer_settime | 111 | timer_delete | 112 | clock_settime |
| 113 | clock_gettime | 114 | clock_getres | 115 | clock_nanosleep |
| 124 | sched_yield | 128 | restart_syscall | 129 | kill |
| 130 | tkill | 131 | tgkill | 132 | sigaltstack |
| 133 | rt_sigsuspend | 134 | rt_sigaction | 135 | rt_sigprocmask |
| 136 | rt_sigpending | 137 | rt_sigtimedwait | 138 | rt_sigqueueinfo |
| 139 | rt_sigreturn | 143 | setregid | 144 | setgid |
| 145 | setreuid | 146 | setuid | 147 | setresuid |
| 148 | getresuid | 149 | setresgid | 150 | getresgid |
| 153 | times | 154 | setpgid | 155 | getpgid |
| 156 | getsid | 157 | setsid | 158 | getgroups |
| 159 | setgroups | 160 | uname | 161 | sethostname |
| 162 | setdomainname | 163 | getrlimit | 166 | umask |
| 168 | getcpu | 169 | gettimeofday | 172 | getpid |
| 173 | getppid | 174 | getuid | 175 | geteuid |
| 176 | getgid | 177 | getegid | 178 | gettid |
| 180 | mq_open | 181 | mq_unlink | 186 | msgget |
| 187 | msgctl | 188 | msgrcv | 189 | msgsnd |
| 190 | semget | 191 | semctl | 192 | semtimedop |
| 197 | shmdt | 198 | socket | 199 | socketpair |
| 200 | bind | 201 | listen | 202 | accept |
| 203 | connect | 204 | getsockname | 205 | getpeername |
| 206 | sendto | 207 | recvfrom | 208 | setsockopt |
| 209 | getsockopt | 210 | shutdown | 211 | sendmsg |
| 212 | recvmsg | 213 | readahead | 214 | brk |
| 215 | munmap | 216 | mremap | 221 | execve |
| 222 | mmap | 226 | mprotect | 240 | rt_tgsigqueueinfo |
| 242 | accept4 | 243 | recvmmsg | 260 | wait4 |
| 261 | prlimit64 | 267 | syncfs | 268 | setns |
| 269 | sendmmsg | 270 | process_vm_readv | 271 | process_vm_writev |
| 276 | renameat2 | 277 | seccomp | 278 | getrandom |
| 279 | memfd_create | 281 | execveat | 291 | statx |
| 436 | close_range | 439 | faccessat2 | 441 | epoll_pwait2 |

### 4.2 ⚠️ 部分实现 — 52 个

| # | Name | # | Name | # | Name |
|---|------|---|------|---|------|
| 0 | io_setup | 1 | io_destroy | 2 | io_submit |
| 3 | io_cancel | 4 | io_getevents | 26 | inotify_init1 |
| 27 | inotify_add_watch | 28 | inotify_rm_watch | 47 | fallocate |
| 97 | unshare | 98 | futex | 116 | syslog |
| 117 | ptrace | 119 | sched_setscheduler | 120 | sched_getscheduler |
| 121 | sched_getparam | 122 | sched_setaffinity | 123 | sched_getaffinity |
| 125 | sched_get_priority_max | 126 | sched_get_priority_min | 140 | setpriority |
| 141 | getpriority | 164 | setrlimit | 165 | getrusage |
| 167 | prctl | 179 | sysinfo | 193 | semop |
| 194 | shmget | 195 | shmctl | 196 | shmat |
| 219 | keyctl | 220 | clone | 223 | fadvise64 |
| 227 | msync | 228 | mlock | 229 | munlock |
| 230 | mlockall | 231 | munlockall | 232 | mincore |
| 233 | madvise | 235 | mbind | 236 | get_mempolicy |
| 237 | set_mempolicy | 283 | membarrier | 284 | mlock2 |
| 286 | preadv2 | 287 | pwritev2 | 293 | rseq |
| 425 | io_uring_setup | 426 | io_uring_enter | 435 | clone3 |

### 4.3 ❌ 未实现 — 56 个

| # | Name | # | Name | # | Name |
|---|------|---|------|---|------|
| 18 | lookup_dcookie | 30 | ioprio_set | 31 | ioprio_get |
| 42 | nfsservctl | 58 | vhangup | 60 | quotactl |
| 75 | vmsplice | 89 | acct | 92 | personality |
| 104 | kexec_load | 105 | init_module | 106 | delete_module |
| 118 | sched_setparam | 127 | sched_rr_get_interval | 142 | reboot |
| 151 | setfsuid | 152 | setfsgid | 170 | settimeofday |
| 171 | adjtimex | 182 | mq_timedsend | 183 | mq_timedreceive |
| 184 | mq_notify | 185 | mq_getsetattr | 217 | add_key |
| 218 | request_key | 224 | swapon | 225 | swapoff |
| 234 | remap_file_pages | 238 | migrate_pages | 239 | move_pages |
| 241 | perf_event_open | 262 | fanotify_init | 263 | fanotify_mark |
| 264 | name_to_handle_at | 265 | open_by_handle_at | 266 | clock_adjtime |
| 272 | kcmp | 273 | finit_module | 274 | sched_setattr |
| 275 | sched_getattr | 280 | bpf | 282 | userfaultfd |
| 285 | copy_file_range | 288 | pkey_mprotect | 289 | pkey_alloc |
| 290 | pkey_free | 292 | io_pgetevents | 424 | pidfd_send_signal |
| 427 | io_uring_register | 428 | open_tree | 429 | move_mount |
| 430 | fsopen | 431 | fsconfig | 432 | fsmount |
| 433 | fspick | 434 | pidfd_open | | |

---

## 5. 未实现 Syscall 按类别分析

| 类别 | 未实现的 Syscall | 不实现的原因 |
|------|-----------------|-------------|
| **内核模块** | `init_module`, `delete_module`, `finit_module`, `create_module`\*, `query_module`\* | 在沙箱内加载内核模块无意义且极度危险 |
| **系统管理** | `reboot`, `swapon`, `swapoff`, `kexec_load`, `kexec_file_load`\* | 不允许 Guest 重启宿主或换内核 |
| **BPF / 性能探测** | `bpf`, `perf_event_open` | 安全风险极高，BPF 可在内核态执行代码 |
| **设备 / IO 端口** | `iopl`\*, `ioperm`\*, `ioprio_set`, `ioprio_get` | x86 端口 I/O，沙箱环境不适用 |
| **高级内存** | `pkey_mprotect`, `pkey_alloc`, `pkey_free`, `userfaultfd`, `remap_file_pages`, `migrate_pages`, `move_pages` | 内存保护密钥、页迁移等高级特性 |
| **文件系统高级功能** | `fanotify_init`, `fanotify_mark`, `name_to_handle_at`, `open_by_handle_at`, `copy_file_range` | 高级文件系统通知 / 操作 |
| **新 mount API** | `fsopen`, `fsmount`, `fsconfig`, `fspick`, `open_tree`, `move_mount` | 新式挂载 API 尚未实现 |
| **进程 fd (pidfd)** | `pidfd_open`, `pidfd_send_signal` | 较新的 pidfd 机制 |
| **审计 / 配额** | `acct`, `quotactl`, `nfsservctl` | 系统级审计 / 配额管理 |
| **时间调整** | `adjtimex`, `settimeofday`, `clock_adjtime` | 不允许调整系统时钟 |
| **身份 / 用户** | `setfsuid`, `setfsgid` | 文件系统级 UID/GID 设置 |
| **遗留 / 废弃** | `uselib`\*, `ustat`\*, `sysfs`\*, `vhangup`, `modify_ldt`\*, `personality`, `vserver`\*, `tuxcall`\*, `security`\*, `sysctl`\* | 已废弃或极其冷门 |

> 标注 `*` 的仅存在于 AMD64 表中。

---

## 6. 实际应用兼容性参考

| 兼容性 | 应用类型 | 说明 |
|--------|---------|------|
| ✅ 正常运行 | Web 应用（Go, Node.js, Python, Java, Rust） | 核心 syscall 全部支持 |
| ✅ 正常运行 | 数据库（MySQL, PostgreSQL, Redis） | 基本正常 |
| ✅ 正常运行 | 常见工具链（gcc, git, curl, wget） | 正常 |
| ⚠️ 功能受限 | 需要 ptrace 的调试器（gdb, strace） | 部分功能不可用 |
| ⚠️ 功能受限 | io_uring 密集型应用 | 实验性支持，部分功能可用 |
| ❌ 无法运行 | 需要 BPF 的工具（bpftrace, eBPF 程序） | `bpf` syscall 未实现 |
| ❌ 无法运行 | 需要加载内核模块的应用 | `init_module` 等未实现 |
| ❌ 无法运行 | perf / 性能分析工具 | `perf_event_open` 未实现 |
| ❌ 无法运行 | 需要 fanotify 的杀毒 / 安全扫描软件 | `fanotify_*` 未实现 |

---

## 7. 总结

gVisor 实现了约 **80% 的 Linux syscall**（完全 + 部分），覆盖了绝大多数常规应用场景。未实现的主要是**内核管理、硬件直访、BPF/性能探测**等本身就不应该在沙箱里做的事情 —— 这不是缺陷，而是有意为之的安全设计选择。

核心安全原则：**Sentry 是唯一与宿主机内核通信的组件，它仅使用约 20 个 syscall 与宿主机交互，极大缩小了攻击面。**
把这个文档整理成markdown push到https://github.com/pingxiaoaws/kata-benchmark-v2/tree/main/gvisor-doc