# MoonDDL

MoonDDL 是一个用 MoonBit 编写的 MySQL 迁移预检 CLI。把迁移前的表结构和这次 PR 里的 SQL 交给它，就能得到一份 Markdown 报告，定位需要复核的变更，并提供可手动执行的只读查询。CLI 本身离线运行。

## 快速开始

安装 [MoonBit 工具链](https://www.moonbitlang.com/download/) 后，在仓库根目录运行：

```sh
moon run --target native cmd/moon-ddl -- check --schema examples/orders/schema.sql --migration examples/orders/add-unique.sql
```

也可以通过 `moon build --release --target native cmd/moon-ddl` 编译，使用构建输出中的 `moon-ddl` 可执行文件。将 stdout 重定向为 `report.md` 即可保存报告。

```text
moon-ddl check --schema schema.sql --migration migration.sql
```

退出码 `0` 表示生成了报告，包含待核查或未分析项时也返回 `0`。无效参数、无法读取 UTF-8 文件或无法可靠切分 SQL 时返回 `2`，错误信息写到 stderr。

## 支持范围

首版面向 MySQL 8.4 InnoDB 单库。`schema.sql` 放迁移前的 `CREATE TABLE` 定义，表名大小写与迁移文件保持一致。迁移文件使用 MySQL 默认的引号和反斜杠规则，以分号切分，每条 `ALTER TABLE` 只支持一个变更子句。

| 迁移变更 | 输出 |
| --- | --- |
| `ADD UNIQUE [INDEX/KEY]`，单列完整索引 | 对非空值执行分组计数的查重 SQL |

组合索引、前缀索引、表达式索引、复合变更和缺少可靠基线的表或字段均显示为「未分析」。同一张表的前序变更会使后续检查失去可靠基线。前序语句影响范围未知时，后续检查统一转为人工复核。

报告基于文件内容提出核查任务。查询结果取决于执行时数据库里的数据。CI 可以把报告追加到 `$GITHUB_STEP_SUMMARY`，供审查迁移 PR 时查看。

## 演示 · 唯一索引迁移

1. 执行快速开始命令，对照[预期报告](examples/orders/expected-report.md)，查看 `add-unique.sql` 第 2 行和查重 SQL。
2. 在专用测试库执行 `schema.sql` 和 `duplicates.sql`。运行报告里的查询，结果为 `PAY-1001` 共两条。执行 `add-unique.sql` 会得到 MySQL 错误 `1062`。
3. 把样例里第二笔订单的流水号改为 `PAY-1002`。再次执行查询应返回零行，此时重跑 `add-unique.sql` 应成功。两笔 `NULL` 订单仍保留。

## 验证

```sh
moon check --target native --deny-warn
moon test --target native --deny-warn
```

GitHub Actions 使用 MySQL 8.4 服务执行 `python tests/mysql_integration.py`。本地复跑时，先准备一个专用的 `moonddl_test` 库和拥有该库权限的测试账户。脚本会在该库创建和清理 `orders` 表。

测试读取 `MYSQL_BIN`、`MYSQL_HOST`、`MYSQL_PORT`、`MYSQL_USER` 和 `MYSQL_PWD`。默认连接 `moonddl@127.0.0.1:3306`，可用 `MOONDDL_BIN` 指定已经编译的 CLI。测试从实际生成的 Markdown 报告提取查询，再与 MySQL 执行迁移的结果比对。
