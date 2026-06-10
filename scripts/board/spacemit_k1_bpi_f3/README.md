# SpacemiT K1 / Banana Pi BPI-F3 Board Scripts

## 作用

这个目录只保留当前正式 K1 / BPI-F3 板测主线所需的脚本和支撑目录。

当前正式链路固定为：

```text
SPL -> OpenSBI(M-mode firmware) -> S-mode scheduler FIT -> 标准 ACT ELF
```

也就是说，这里服务的目标不是历史 fake-u-boot、bootfs FIT suite、batch campaign 或 TFTP/raw payload 路线，而是当前唯一仍在用的 scheduler 板测链。

## 当前主执行面

当前正式 K1 主线固定拆成三层：

- 服务器 `/home/zhangyu/rvtest`
  - 只负责把活跃源码和最小 SDK 产物推到下位机
  - 验证结束后把源码修改、日志和可选 suite 产物拉回
  - 承担唯一 Git 真仓和唯一 GitHub 代推入口
- 下位机宿主机 `/home/codex/rvtest`
  - 负责启动/重启主线 `rvtest` 容器
  - 负责 SD 卡分区写入、串口采集和结果解析
- 下位机容器 `rvtest`
  - 负责 `make tests`
  - 负责 K1 专用 `make elfs`
  - 负责 `build_k1_scheduler_image_custom.sh` / `build_k1_scheduler_image.sh`

当前正式下位机固定路径：

- 源码树：`/home/codex/rvtest/riscv-arch-test-act4/`
- 最小 SDK 产物树：`/home/codex/rvtest/buildroot-sdk-2.2/`
- 日志根目录：`/home/codex/rvtest/logs/`

## 当前活跃脚本

### `prepare_k1_bianbu_buildroot_2_2.sh`

当前正式 K1 Buildroot SDK 源码准备入口。

它服务的对象不是 ACT ELF、scheduler FIT 打包或板测日志解析，而是官方
`buildroot-sdk-2.2` 源码树本身。

核心输入：

- 一个 fresh 或可同步的官方 SDK 根目录
- 仓内固化的 patch series：
  - `buildroot_sdk_2_2_patch_series/opensbi/`
  - `buildroot_sdk_2_2_patch_series/uboot-2022.10/`
  - `buildroot_sdk_2_2_patch_series/buildroot-ext/`

核心处理：

- 必要时执行 `repo init` 与 `repo sync`
- 对 `opensbi`、`uboot-2022.10`、`buildroot-ext` 回放补丁序列
- 把三个关键子仓切到本地准备分支 `act4-k1-sdk-prepared`
- 把 fresh SDK 改造成当前项目实际使用版本
- 输出 branch / commit / `repo status`

它适合做什么：

- 从官方 manifest 获取一份 fresh SDK
- 把官方 SDK 变成当前项目使用版本
- 对现有 SDK 做 `--verify-only` 核对

它不负责什么：

- 不编译 `k1_v2`
- 不生成 ACT ELF
- 不写卡
- 不解析串口日志

### `sync_k1_lower_workspace.sh`

当前正式的“服务器 <-> 下位机”工作区同步入口。

它服务的对象不是 Docker 镜像，也不是完整 SDK 源码树，而是：

- 一份不带 `.git` 历史的下位机普通源码树
- 下位机板测真正需要的最小 SDK 三个固定文件
- 下位机本轮产生的源码修改、日志和可选 suite 产物

固定模式：

- `push`
  - 从服务器推送活跃源码树到 `/home/codex/rvtest/riscv-arch-test-act4/`
  - 只同步最小 SDK 产物：
    - `FSBL.bin`
    - `fw_dynamic.itb`
    - `k1-x_deb1.dtb`
- `pull`
  - 把下位机源码修改和 `logs/k1-board/` 拉回服务器
  - 可选附带某一轮 suite 产物快照

固定排除：

- `.git/`
- `.gitmodules`
- `.venv/`
- `.trash/`
- `work/`
- `logs/`
- `delivery/`
- `__pycache__/`
- `.pytest_cache/`
- `.ruff_cache/`

它适合做什么：

- 把服务器当前活跃源码树下发到下位机
- 把下位机板测产生的源码修改和日志回收到服务器
- 维持“下位机可维护、服务器可发布”的分工

它不负责什么：

- 不启动 Docker 容器
- 不写卡
- 不直接 Git 提交

### `publish_k1_lower_sync.sh`

当前正式的服务器代推入口。

它只在服务器 Git 工作树中执行，用来把最近一次 `pull` 回来的源码改动提交并推送到当前个人分支。

核心护栏：

- 只读取最近一次 `pull` 记录的 `pulled_paths.txt`
- 只 `git add` 这些本轮真正从下位机覆盖回来的源码路径
- 如果这些路径和 `pre_pull_dirty.txt` 记录的服务器原有脏改动有交集，就直接拒绝提交

它适合做什么：

- 把下位机改动安全回收并代推 GitHub
- 避免把服务器本地无关脏改动卷进同一次提交

它不负责什么：

- 不做同步
- 不拉日志
- 不在下位机执行

### `verify_k1_env.sh`

当前正式的下位机环境验证入口。

它固定做这几件事：

- 检查 `docker` 命令和当前用户的 docker 访问方式
- 检查 `/home/codex/rvtest/` 下当前交付恢复出来的核心目录
- 检查运行中的 `rvtest` 容器元数据是否符合当前交付模型
- 检查最小 SDK 三个固定文件是否存在
- 检查串口入口、SD 卡分区标签和宿主机辅助工具是否齐全

当前交付模型固定为：

- 先在交付目录中执行 `restore.sh`
- 再执行交付目录中的 `run-rvtest.sh`
- 然后在下位机源码树中执行 `verify_k1_env.sh`

当前默认检查项：

- 工作区根：`/home/codex/rvtest`
- 容器名：`rvtest`
- 可选镜像期望值：`--expect-image <tag>`

当前容器口径固定检查：

- 容器必须存在且处于 `running`
- 工作目录必须是 `/workspace/riscv-arch-test-act4`
- 容器用户必须是 `root`
- 当前交付模型下的挂载必须是：
  - `/home/codex/rvtest -> /workspace`

它适合做什么：

- 在下位机上验收当前 K1 板测环境是否到位
- 快速区分“交付容器没起来”和“最小 SDK 没补齐”
- 在进入 `make tests`、`make elfs`、scheduler 打包之前先卡住环境问题

它不负责什么：

- 不启动或重启容器
- 不同步源码
- 不写卡
- 不提交 Git

### `build_k1_scheduler_image.sh`

当前正式主入口。

它负责把“已经生成好的标准 ACT ELF”收口成一套可上板的 scheduler 镜像。

核心输入：

- 从 `work/spacemit-k1-bpi-f3-scheduler/elfs/<scope>/` 收集标准 ACT ELF
- 根据 `--scope`、`--scope-set` 或 `--scopes-file` 选择要打包的测试范围
- 可选接收：
  - `--fsbl`
    - 覆盖默认 `FSBL.bin`
  - `--opensbi`
    - 覆盖默认 `fw_dynamic.itb`
  - `--sdk-dtb`
    - 覆盖默认 `k1-x_deb1.dtb`
  - `--output-root`
    - 覆盖默认输出目录

核心处理：

- 重新构建 scheduler 本体
- 生成 `selected-scopes.txt`
- 生成 `manifest.tsv`
- 把 scheduler 与多条 ELF 一起打进单个 `u-boot.itb`
- 生成可直接执行的 `flash-command.sh`

典型使用场景：

- `--only I-addi-00`
  - 生成 scheduler smoke，用来先确认 OpenSBI -> S-mode scheduler handoff、trap 恢复和单条测试回收
- `--scope rv64i/I`
  - 跑一个完整 scope
- `--scope-set k1-qemu-rv64-max-v1`
  - scope-set 对照 preset，不是当前默认板测集合
- `--scope-set k1-supported-v1`
  - 能力超集对照 preset，不是当前默认板测入口
- `--timeout-ms 10000`
  - 当前正式默认单测超时配置
- `--timeout-ms 0`
  - 关闭 scheduler 小型 OS 的 Sstc supervisor-timer 回收，适合只做对照或定位 timeout 机制本身

主要输出目录：

- `work/spacemit-k1-bpi-f3-scheduler/<suite-name>/`

主要输出文件：

- `selected-scopes.txt`
- `manifest.tsv`
- `scheduler.elf`
- `scheduler.bin`
- `u-boot.itb`
- `flash-command.sh`

你应该在什么时候用它：

- 你已经按 K1 当前正式板测集合执行过 `make elfs`
  例如：
  `EXTENSIONS="$(sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' scripts/board/spacemit_k1_bpi_f3/extension_sets/k1-smode-packable-v1.txt | paste -sd, -)" CONFIG_FILES=config/cores/spacemit-k1-bpi-f3-scheduler/test_config.yaml make elfs`
- 你要把一个 smoke / scope / scope-set 打成正式上板镜像
- 你需要生成和当前正式 K1 主线一致的 `manifest.tsv` 与 `flash-command.sh`

它不负责什么：

- 不生成 ACT ELF
- 不直接写卡
- 不解析串口日志

### `build_k1_scheduler_image_custom.sh`

当前正式主脚本的过滤包装入口。

它的职责不是替代 `build_k1_scheduler_image.sh`，而是在“不改正式 preset 文件”的前提下，
按一次性的板测需要定制 scope 集合，然后仍旧调用正式主脚本完成最终打包。

核心输入：

- 一个 base scope 来源，三选一：
  - `--base-scope <family/ext>`
  - `--base-scope-set <preset-name>`
  - `--base-scopes-file <path>`
- 一个 base extension 来源，三选一：
  - `--base-extension <ext>`
  - `--base-extension-set <preset-name>`
  - `--base-extensions-file <path>`
- 可选的过滤项：
  - `--exclude-scope <family/ext>`
  - `--include-scope <family/ext>`
  - `--exclude-extension <ext>`
  - `--include-extension <ext>`
- 以及与正式主脚本一致的可透传参数：
  - `--suite-name`
  - `--only`
  - `--timeout-ms`
  - `--fsbl`
  - `--opensbi`
  - `--sdk-dtb`
  - `--output-root`

核心处理：

- 读取 base scope 集合
- 或把 base extension 集合解析成当前已有 ELF 对应的 scope 集合
- 去重、按顺序过滤、按需追加 include scope
- 支持把官方扩展名直接映射到当前 ACT scope
  - `RV64I -> rv64i/I`
  - `A -> rv64i/Zaamo + rv64i/Zalrsc`
  - `C -> rv64i/Zca + rv64i/Zcd`
- 在 `work/spacemit-k1-bpi-f3-scheduler/generated-scopes/` 下生成一份临时 scope 文件
- 再调用 `build_k1_scheduler_image.sh --scopes-file ...` 完成正式打包

典型使用场景：

- `--base-scope-set k1-qemu-rv64-max-v1 --exclude-scope priv/ZicntrS`
  - 在不改正式 35-scope preset 的前提下，先排除 `ZicntrS` 做一轮板测
- `--base-extension-set k1-smode-packable-v1`
  - 当前板测推荐入口，直接按当前 K1 scheduler S-mode 可打包扩展集生成镜像
- `--base-extension RV64I --base-extension M --base-extension A --include-extension Zbb`
  - 只挑选你明确指定的扩展，不必手写底层 scope 名
- `--base-scopes-file <path> --include-scope rv64i/Zbb`
  - 基于一份已有 scope 清单补进新的扩展

它适合做什么：

- 做一次性的板测过滤
- 按“扩展名”而不是“scope 路径”自定义打包
- 保留正式 preset 不变，同时快速生成对照镜像
- 把“哪些扩展被排除/补入”固化到生成的 scope 文件里，方便回看

它不负责什么：

- 不改正式 preset 文件
- 不改变正式 scheduler/FIT 打包逻辑
- 不绕过 `build_k1_scheduler_image.sh`

### `flash_k1_test_card.sh`

当前正式写卡入口。

它负责把上一步已经准备好的镜像真正写进下位机上的 SD 卡分区。

核心输入：

- 准备正式板测链需要的镜像和配置
- 在下位机上写入 SD 卡目标分区
- 支持这些输入类型：
  - `--fsbl`
  - `--opensbi`
  - `--uboot-itb`
  - `--env-bin`
  - `--bootfs-tree`
  - `--bootfs-elf`
  - `--bootfs-dest`
  - `--bootfs-purge-prefix`

核心处理：

- 在服务器模式下：
  - 通过 SSH / SCP 把本地产物传到下位机工作目录
  - 在下位机上按分区标签写入 `fsbl`、`opensbi`、`uboot`、`env`
- 在下位机本地模式下：
  - 直接在本机 staging 产物
  - 直接在本机按分区标签写入 `fsbl`、`opensbi`、`uboot`、`env`
- 如有要求，再挂载 `bootfs` 并同步 bootfs 树或单个 ELF
- 对 `localhost:2222` 这类反向 SSH 入口保持宿主机直连，不再额外交给容器转发

在当前正式主线里，它的主要职责是：

- 写 `FSBL.bin`
- 写 `fw_dynamic.itb`
- 写 scheduler 版 `u-boot.itb`

当前新的默认 helper 行为是：

- 如果本机能直接看到 `/dev/disk/by-partlabel/fsbl`、`opensbi`、`uboot`
  - `flash-command.sh` 会优先走下位机本地模式
- 如果这些分区标签在本机不可见
  - 继续保留旧的 SSH/scp 远程写卡路径
- 如需强制指定
  - `K1_LOWER_LOCAL=1`
    - 强制下位机本地写卡
  - `K1_LOWER_LOCAL=0`
    - 强制服务器 SSH/scp 写卡

它之所以仍保留 `env` / `bootfs` 相关参数，是为了兼容历史归档路线的回看和诊断；这些能力不再构成当前推荐主流程。

你应该在什么时候用它：

- `build_k1_scheduler_image.sh` 已经生成好 `flash-command.sh`
- 如果走服务器远程模式，已经确认下位机 `ssh -i ~/.ssh/k1_lower_ed25519 -o IdentitiesOnly=yes -p 2222 codex@localhost` 或等价链路可用
- 如果走下位机本地模式，已经确认本机能看到 `fsbl`、`opensbi`、`uboot` 分区标签
- 你要把 scheduler smoke / scope / scope-set 镜像真正刷到卡上

它不负责什么：

- 不挑选测试集合
- 不生成 FIT
- 不判断测试 PASS/FAIL

### `parse_k1_scheduler_log.py`

当前正式日志解析入口。

它负责把“串口原始日志”重新整理成一份按测试逐条对应的结果表。

核心输入：

- 读取 scheduler 生成的 `manifest.tsv`
- 解析串口日志中的：
  - `ACT-SCHED: CASE`
  - `ACT-SCHED: RESULT`
  - `ACT-SCHED: LOAD_ERROR`
  - `ACT-SCHED: TIMEOUT`
  - `RVCP-SUMMARY`
- 输出逐条测试结果 TSV

主要输出：

- 默认写到标准输出
- 指定 `--output` 时写到目标 TSV 文件

输出字段：

- `index`
- `name`
- `relpath`
- `status`
- `summary_test`
- `notes`

当前结果状态口径：

- `PASS`
- `FAIL`
- `LOAD_ERROR`
- `UNEXPECTED_RETURN`
- `TIMEOUT`

当前正式口径里，测试侧只负责 `PASS/FAIL` 的 `ebreak` 返回；像 trap 内失败循环、
异常 `ecall` 或非预期 trap 这类未正常回传到 scheduler 的 case，统一由小型 OS
回收成 `TIMEOUT`，并在对应错误行里保留 `reason/cause/epc/tval` 细节。

它对应的是当前正式 scheduler 串口格式，不适用于旧 `ACT-SUITE` 或 `ACT-CAMPAIGN` 日志。

你应该在什么时候用它：

- 你已经拿到一轮 scheduler 串口日志
- 你要把日志和 `manifest.tsv` 对齐，得到逐条 case 的状态表
- 你要从 `ACT-SCHED:*` 原始文本回收出更稳定的 TSV 结果

它不负责什么：

- 不抓串口
- 不生成 manifest
- 不解析旧 bootfs suite 或 campaign 日志

## 当前活跃支撑目录

### `scheduler/`

当前正式 scheduler 实现源码目录。

主要包含：

- `start.S`
  - 入口、栈、`gp`、S-mode trap 入口和上下文切换相关初始化
- `runtime_layout.h`
  - trap frame 布局、事件枚举和 ASM/C 共用偏移定义
- `scheduler.c`
  - UART 输出、manifest 遍历、ELF loader、case loop、S-mode trap 分类与 Sstc timeout 回收
- `link.ld`
  - scheduler 自身链接地址与布局

### `scope_sets/`

当前正式 scope preset 目录。

作用：

- 保存可复用的 scope 集合文本文件
- 供 `build_k1_scheduler_image.sh --scope-set <name>` 直接读取

当前最关键的 preset 是：

- `k1-qemu-rv64-max-v1.txt`
  - scope-set 对照 preset
- `k1-supported-v1.txt`
  - 能力超集对照 preset

### `extension_sets/`

当前正式的扩展级 preset 目录。

作用：

- 保存可复用的扩展集合文本文件
- 供 `build_k1_scheduler_image_custom.sh --base-extension-set <name>` 直接读取

当前最关键的 preset 是：

- `k1-smode-packable-v1.txt`
  - 当前 K1 scheduler 在 S-mode 板测链里的当前板测扩展集合
  - 已自动排除：
    - 当前没有独立 packable ACT scope 的配置项
    - 当前不属于 S-mode scheduler 正式板测入口的 `priv/*` 扩展

## 当前正式脚本一览表

| 脚本 / 目录 | 当前状态 | 解决的问题 | 主要输入 | 主要输出 |
| --- | --- | --- | --- | --- |
| `build_k1_scheduler_image.sh` | 活跃 | 把多条标准 ACT ELF 打成 scheduler FIT | scopes、scope set、`FSBL.bin`、`fw_dynamic.itb`、DTB | `manifest.tsv`、`u-boot.itb`、`flash-command.sh` |
| `build_k1_scheduler_image_custom.sh` | 活跃 | 在不改 preset 的前提下按 scope 或 extension 定制集合并转交正式打包 | base scope / extension、include/exclude scope / extension、正式打包参数 | 生成 scope 文件、`manifest.tsv`、`u-boot.itb`、`flash-command.sh` |
| `sync_k1_lower_workspace.sh` | 活跃 | 在服务器与下位机之间同步活跃源码树、最小 SDK 产物和日志 | 服务器源码树、最小 SDK 三文件、下位机日志 | 下位机普通源码树、服务器回收日志、可选 suite 产物 |
| `publish_k1_lower_sync.sh` | 活跃 | 只发布本轮从下位机回收的源码修改 | `pulled_paths.txt`、`pre_pull_dirty.txt`、当前 Git 分支 | 服务器 Git 提交与 GitHub 推送 |
| `verify_k1_env.sh` | 活跃 | 在下位机静态验证当前 K1 板测环境是否齐全 | 下位机工作区、运行中的 `rvtest` 容器、最小 SDK 三文件、串口与分区标签 | `PASS/FAIL` 检查结果与退出码 |
| `flash_k1_test_card.sh` | 活跃 | 把镜像写进 SD 卡实际分区，支持服务器远程模式和下位机本地模式 | `fsbl`、`opensbi`、`u-boot.itb`、可选 `env` / `bootfs` | 下位机分区写入结果 |
| `parse_k1_scheduler_log.py` | 活跃 | 把 scheduler 串口日志转成逐条结果表 | `manifest.tsv`、serial log | TSV 结果表 |
| `scheduler/` | 活跃 | scheduler 本体源码与链接布局 | C / ASM / linker 输入 | `scheduler.elf`、`scheduler.bin` 的源码基础 |
| `scope_sets/` | 活跃 | 复用 scope preset | preset 文本文件 | 被 `--scope-set` 直接消费 |
| `extension_sets/` | 活跃 | 复用扩展 preset，并自动映射到底层 ACT scope | extension 文本文件 | 被 `--base-extension-set` 直接消费 |

## 已归档脚本

下面这些脚本已经退出当前活跃目录，统一归档到：

- `../../../archive/k1/scripts/spacemit_k1_bpi_f3/`

归档脚本包括：

- `build_test_uboot_itb.sh`
  - 历史 fake-u-boot 单测 FIT 打包
- `prepare_k1_bootfs_fit_suite.sh`
  - 历史 bootfs FIT suite 准备
- `parse_k1_suite_log.py`
  - 历史 `ACT-SUITE` 串口日志解析
- `prepare_k1_single_scope_suite.sh`
  - 历史单 scope 逐条 fake-u-boot suite
- `prepare_k1_campaign.sh`
  - 历史 batch campaign 构建
- `parse_k1_campaign_log.py`
  - 历史 `ACT-CAMPAIGN` 日志解析
- `verify_k1_campaign.sh`
  - 历史 campaign / bootfs 写卡前校验
- `build_uboot_direct_payload.sh`
  - 历史 raw payload 构建
- `run_single_uboot_payload_test.sh`
  - 历史 raw payload 单轮执行
- `stage_tftp_payload.sh`
  - 历史 TFTP 投放
- `stage_tftp_elf.sh`
  - 历史 TFTP wrapper
- `build_test_itb.sh`
  - 历史 standalone firmware FIT 路线
- `build_uboot_direct_elf.sh`
  - 历史 direct payload wrapper
- `build_uboot_elf.py`
  - 历史 header rewrite helper
- `run_k1_uboot_tests.ps1`
  - 历史 Windows 串口/TFTP runner
- `payloads/uart_hello_mmode.S`
  - 历史 raw payload hello 示例

这些脚本不再作为当前推荐步骤的一部分；如果需要回看，请先看归档索引：

- `../../../archive/k1/README.md`
- `../../../archive/k1/scripts/spacemit_k1_bpi_f3/README.md`

## 推荐阅读

- `../../../project_docs/README.md`
- `../../../project_docs/K1测试说明.md`
- `../../../references/project-docs-map.md`
