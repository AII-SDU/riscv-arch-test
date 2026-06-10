# SpacemiT K1 / Banana Pi BPI-F3 scheduler board configuration

这个目录是当前 K1 的：

- 唯一活跃 ACT 配置
- 唯一推荐构建入口
- 唯一持续维护的配置目录

当前正式链路固定为：

```text
SPL -> OpenSBI(M-mode handoff) -> scheduler FIT -> 标准 ACT ELF
```

当前正式构建入口固定为：

- `test_config.yaml`

当前地址分工固定为：

- `0x00200000`：scheduler 本体和 FIT handoff 入口
- `0x60000000`：scheduler 版标准 ACT ELF 运行地址
- `[0x60000000, 0x78000000)`：scheduler 允许装载测试 ELF 的正式窗口

当前最关键的配置语义是：

- `link.ld` 负责把 scheduler 版标准 ACT ELF 链接到 `0x60000000`
- `rvmodel_macros.h` 负责 `PASS/FAIL` 通过 `a0=0/1; ebreak` 返回 scheduler
- scheduler 小型 OS 负责额外的 trap、timeout 和继续调度能力

当前目录按“自包含、独立维护”的原则组织：

- 不通过 `include` 或符号链接直接复用 `../spacemit-k1-bpi-f3/`
- 后续 K1 的能力声明、测试选择、板测入口和调度镜像构建，默认都只更新当前目录

标准 K1 目录仍保留在仓库中，但它现在只是：

- `deprecated/frozen` 的兼容残留
- 非当前主流程入口

完整板测路径见：

- `../../../project_docs/K1测试说明.md`
