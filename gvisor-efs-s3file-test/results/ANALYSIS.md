# S3 Files + gVisor I/O Benchmark Analysis

## 测试环境

| 项目 | 值 |
|------|-----|
| 集群 | test-s4, EKS 1.34, us-west-2 |
| 节点 | ip-172-31-9-46 (m7g.2xlarge, 8 vCPU, 32 GiB, Graviton3) |
| S3 Bucket | gvisor-s3files-test-970547376847 |
| S3 Files FS | fs-0987d9f1d827a8767 |
| EFS CSI Driver | v3.0.0-eksbuild.1 |
| gVisor | release-20260406.0, DirectFS |
| fio | 3.28 |
| fio 参数 | ioengine=psync, numjobs=4, runtime=60s, size=512M, fsync_on_close=1 |

## 测试矩阵

| Pod | 运行时 | UID | PV 类型 | 说明 |
|-----|--------|-----|---------|------|
| s3files-bench-runc | runc | root | Static (无 AP) | 基准对照 |
| s3files-bench-gvisor | gVisor | root | Static (无 AP) | gVisor 默认 |
| s3files-bench-gvisor-uid1000 | gVisor | 1000 | Dynamic (AP uid=1000) | 生产推荐 |

## 吞吐量结果 (MiB/s)

### Sequential Read

| Block Size | runc | gVisor (root) | gVisor (uid=1000) | gVisor root vs runc | gVisor uid1000 vs runc |
|-----------|------|---------------|-------------------|-------|--------|
| 4k | 2,150 | 1,598 | 1,438 | -26% | -33% |
| 128k | 3,516 | 15,639 | 16,011 | **+345%** | **+355%** |
| 1M | 3,524 | 28,025 | 51,753 | **+695%** | **+1369%** |

### Sequential Write

| Block Size | runc | gVisor (root) | gVisor (uid=1000) | gVisor root vs runc | gVisor uid1000 vs runc |
|-----------|------|---------------|-------------------|-------|--------|
| 4k | 830 | 1,199 | 980 | +44% | +18% |
| 128k | 1,653 | 6,130 | 10,335 | **+271%** | **+525%** |
| 1M | 1,529 | 7,479 | 14,119 | **+389%** | **+823%** |

### Random Read

| Block Size | runc | gVisor (root) | gVisor (uid=1000) | gVisor root vs runc | gVisor uid1000 vs runc |
|-----------|------|---------------|-------------------|-------|--------|
| 4k | 34 | 756 | 1,239 | **+2,108%** | **+3,517%** |
| 128k | 681 | 13,167 | 17,441 | **+1,833%** | **+2,461%** |

### Random Write

| Block Size | runc | gVisor (root) | gVisor (uid=1000) | gVisor root vs runc | gVisor uid1000 vs runc |
|-----------|------|---------------|-------------------|-------|--------|
| 4k | 188 | 1,256 | 888 | **+568%** | **+372%** |
| 128k | 1,194 | 5,603 | 10,153 | **+369%** | **+751%** |

## 关键分析

### 1. gVisor 的 VFS 缓存效应（最重要的发现）

**gVisor 的吞吐量比 runc 高 3-36 倍，这不代表 gVisor 更快，而是因为 gVisor 的 9p VFS 缓存完全吸收了 I/O。**

原理：
- runc 通过 NFS4 直接访问 S3 Files 后端，page cache 行为受内核控制
- gVisor 使用 9p 协议 + DirectFS，所有文件 I/O 先经过 gVisor 内部的 VFS 缓存层
- gVisor 的 `cache=remote_revalidating` 模式会缓存数据在 sandbox 的用户态内存中
- `O_DIRECT` flag 被 gVisor VFS 层忽略（验证：direct=1 对 gVisor 无效，结果不变）
- `fsync_on_close=1` 也无法强制 gVisor 将数据写到 NFS 后端

**结论：gVisor 和 runc 的 fio 数据不可直接比较**，因为测量的是不同东西：
- runc: 测的是 S3 Files NFS4 后端的真实性能
- gVisor: 测的是 gVisor VFS 用户态缓存的吞吐量（本质上是内存读写速度）

这和之前 Kata/virtiofs 的 cache 问题完全类似。

### 2. S3 Files 后端真实性能（runc 数据）

从 runc 数据可以看到 S3 Files 的真实后端特征：

| 指标 | 值 | 说明 |
|------|-----|------|
| Seq Read 128k | 3,516 MiB/s | 接近实例网络带宽上限 |
| Seq Write 128k | 1,653 MiB/s | 写入约为读取的一半 |
| Rand Read 4k | 34 MiB/s (8,770 IOPS) | 小块随机读性能差（S3 对象存储开销） |
| Rand Write 4k | 188 MiB/s (48K IOPS) | page cache writeback |
| Seq Read 1M | 3,524 MiB/s | 大块性能稳定 |

**S3 Files 特征**：
- 顺序大块读性能优秀（~3.5 GiB/s，接近 m7g.2xlarge 的 25 Gbps 网络带宽）
- 小块随机读 IOPS 较低（8.7K）— S3 对象存储的 GET 延迟约 0.45ms
- 写入吞吐约为读取的一半
- 非常适合 AI/ML 训练数据的顺序读取场景

### 3. runc 4k 顺序读高但随机读极低的原因

| 模式 | 4k 吞吐 | 4k IOPS |
|------|---------|---------|
| Seq Read | 2,150 MiB/s | 550K | 
| Rand Read | 34 MiB/s | 8.7K |

差距 63 倍！原因：
- 顺序读时 NFS4 readahead 预读大量数据，page cache 命中率极高
- 随机读时每次 4k 都可能 cache miss，需要到 S3 后端取数据
- S3 Files 每个 GET 请求约 0.45ms 延迟，4 个 numjobs 并发只能达到 ~8.7K IOPS

### 4. gVisor uid=1000 比 gVisor root 更快的异常

在大块测试中，uid=1000 的吞吐量甚至高于 root：
- read 1M: uid1000 = 51,753 vs root = 28,025 (+85%)
- write 128k: uid1000 = 10,335 vs root = 6,130 (+69%)

这可能与两者使用不同的 PV 有关：
- gVisor root 使用 Static PV（挂载整个 filesystem）
- gVisor uid1000 使用 Dynamic PV（通过 Access Point 挂子目录）

Access Point 子目录可能有更小的 namespace，缓存效率更高。但由于都是 gVisor VFS 缓存，这个差异没有生产意义。

### 5. 可用性总结

| 配置 | Static PV (无 AP) | Dynamic PV (有 AP) |
|------|---|---|
| runc (root) | ✅ 读写正常 | ✅ 读写正常 |
| gVisor (root) | ✅ 读写正常 | ❌ Operation not permitted |
| gVisor (uid=1000) | — | ✅ 读写正常 |

## 生产建议

### 推荐方案：gVisor + S3 Files Dynamic PV + uid=1000

```yaml
securityContext:
  runAsUser: 1000
  runAsGroup: 1000
```

配合 Dynamic StorageClass：
```yaml
parameters:
  provisioningMode: s3files-ap
  fileSystemId: "fs-xxx"
  directoryPerms: "700"
  uid: "1000"
  gid: "1000"
```

### 性能注意事项

1. **gVisor VFS 缓存使 I/O 看起来很快**：实际数据持久化受 9p writeback 策略控制，不保证实时落盘
2. **S3 Files 顺序大块读性能优秀**：适合 AI/ML 数据集加载（~3.5 GiB/s on m7g.2xlarge）
3. **小文件随机读性能有限**：8.7K IOPS @ 4k，不适合数据库或高 IOPS 工作负载
4. **写入吞吐约为读取的一半**：checkpoint/log 写入需要评估

### 与 EFS 的对比

| 维度 | EFS | S3 Files |
|------|-----|----------|
| gVisor root 写入 (Static PV) | ❌ | ✅ |
| gVisor root 写入 (Dynamic PV) | ❌ | ❌ |
| gVisor uid=1000 写入 | ✅ | ✅ |
| 数据存储位置 | EFS 服务 | S3 bucket |
| 适用场景 | 通用文件共享 | AI/ML 数据集, 共享训练数据 |
| 定价模型 | 按存储+吞吐 | S3 存储 + S3 Files 请求 |

## 测试日期

2026-04-19
