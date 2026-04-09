# Test 9: kata-clh Memory Footprint Profiling

**Date:** 2026-04-09
**Node:** ip-172-31-19-254.us-west-2.compute.internal (m8i.4xlarge, 64 GiB RAM, 16 vCPU)
**Total Node Memory:** 63257 MiB
**Runtimes:** runc (baseline) vs kata-clh (cloud-hypervisor)
**Base Image:** registry.k8s.io/pause:3.10

---

## 9A: Single Pod Idle Memory Delta

test,runtime,round,mem_available_before_MiB,mem_available_after_MiB,delta_MiB,timestamp
9A,runc,1,61404,61392,12,2026-04-09T13:32:35Z
9A,runc,2,61403,61393,10,2026-04-09T13:33:09Z
9A,runc,3,61403,61403,0,2026-04-09T13:33:43Z
9A,kata-clh,1,61413,61248,165,2026-04-09T13:34:17Z
9A,kata-clh,2,61406,61237,169,2026-04-09T13:34:51Z
9A,kata-clh,3,61402,61235,167,2026-04-09T13:35:25Z

---

## 9B: cloud-hypervisor Process RSS

test,round,clh_pid,VmRSS_kB,VmHWM_kB,RssAnon_kB,RssFile_kB,RssShmem_kB,Pss_kB,timestamp
9B,1,3362795,153080,153080,1320,3804,147960,151944,2026-04-09T13:35:47Z
9B,1,3362890,,,,,,,2026-04-09T13:35:50Z
9B,1,3362896,,,,,,,2026-04-09T13:35:53Z
9B,2,3363729,153712,153712,1320,3804,148592,152578,2026-04-09T13:36:15Z
9B,2,3363822,,,,,,,2026-04-09T13:36:19Z
9B,2,3363828,,,,,,,2026-04-09T13:36:22Z
9B,3,3364534,153412,153412,1316,3804,148292,152394,2026-04-09T13:36:44Z
9B,3,3364642,,,,,,,2026-04-09T13:36:47Z
9B,3,3364648,,,,,,,2026-04-09T13:36:50Z

---

## 9C: Cgroup Memory Accounting

test,runtime,pod_name,pod_uid,cgroup_memory_current_bytes,cgroup_memory_MiB,timestamp
9C,runc,t9c-runc,b33051b7-437b-4598-a582-0f5aa6c12eef,495616,.47,2026-04-09T13:37:15Z
9C,kata-clh,t9c-kata-clh,d50820de-5ae4-41e3-a454-36dbe7f1e940,0,0,2026-04-09T13:37:30Z

---

## 9D: Memory Overhead Under Stress

test,runtime,stress_MiB,mem_available_before_MiB,mem_available_after_MiB,delta_MiB,timestamp
9D,runc,0,61399,61389,10,2026-04-09T13:38:30Z
9D,kata-clh,0,61400,61198,202,2026-04-09T13:39:30Z
9D,runc,256,61400,61119,281,2026-04-09T13:40:44Z
9D,kata-clh,256,61391,60938,453,2026-04-09T13:41:59Z
9D,runc,512,61397,60864,533,2026-04-09T13:43:13Z
9D,kata-clh,512,61401,60677,724,2026-04-09T13:44:28Z
9D,runc,1024,61401,60358,1043,2026-04-09T13:45:42Z
9D,kata-clh,1024,61418,60153,1265,2026-04-09T13:46:57Z

---

## 9E: Multi-Pod Linearity

test,runtime,num_pods,mem_available_before_MiB,mem_available_after_MiB,total_delta_MiB,per_pod_delta_MiB,timestamp
9E,runc,1,61399,61390,9,9.0,2026-04-09T13:48:01Z
9E,kata-clh,1,61403,61228,175,175.0,2026-04-09T13:49:06Z
9E,runc,2,61399,61397,2,1.0,2026-04-09T13:50:11Z
9E,kata-clh,2,61407,61066,341,170.5,2026-04-09T13:51:17Z
9E,runc,4,61396,61381,15,3.7,2026-04-09T13:52:25Z
9E,kata-clh,4,61406,60728,678,169.5,2026-04-09T13:53:34Z
9E,runc,8,61415,61341,74,9.2,2026-04-09T13:54:47Z
9E,kata-clh,8,61399,60064,1335,166.8,2026-04-09T13:56:02Z

---

*Results files:*
- `v2-test9a-idle-memory-delta.csv`
- `v2-test9b-clh-rss.csv`
- `v2-test9c-cgroup-vs-top.csv`
- `v2-test9d-stress-overhead.csv`
- `v2-test9e-multi-pod-linearity.csv`
