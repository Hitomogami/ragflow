# RAGFlow Fork 升级合并方案：main → v0.26.1

> 生成日期：2026-06-19
> 目标：将本地 fork 的全部定制项保留并迁移到官方 v0.26.1
> 范围决定：**全部保留**（PostgreSQL 迁移 + 端口重映射 + 本地镜像 + 全部代码改动）

## 一、当前结构

| 项 | 说明 |
|---|---|
| `main` | = 官方 `8f0632c8d`（v0.25.6 时期）+ **仅 1 个自定义提交** `39ac85249 迁移至 0.25.6` |
| 分叉点 (merge-base) | `8f0632c8d`，就在 v0.25.6 附近 |
| `v0.26.1` | 领先分叉点 **426 个提交** |
| 自定义改动规模 | 22 个文件，+399 / −202 行 |

所有定制浓缩在一个提交里。22 个文件中有 **18 个**官方在 0.26.1 也改过，直接 rebase/cherry-pick 会一次性爆出大量冲突，故采用「拉新分支 + 按类别分批重放」。

## 二、自定义改动分类

### A 类 — 部署/配置类（机械冲突，易重放）
- `docker/.env`、`web/.env`：端口重映射（80/9380→6100-6106）、`DB_TYPE=postgres`、`EMBEDDING_BATCH_SIZE=5`、`GRAPH_EMBEDDING_CONCURRENCY=2`、`RAGFLOW_IMAGE` 本地镜像
- `conf/service_conf.yaml`、`docker/service_conf.yaml.template`：MySQL→PostgreSQL 配置块
- `docker/docker-compose.yml`、`docker-compose-base.yml`：postgres 服务 + 端口
- `Dockerfile`、`.dockerignore`、`.gitignore`、`docker/entrypoint.sh`、`download_deps.py`：本地镜像构建
- `uv.lock`：**直接丢弃**，从 0.26.1 重新 `uv lock` 生成

### B 类 — 代码逻辑类（需谨慎手工合并）
- `api/db/db_models.py`：PostgreSQL **schema 支持**（search_path、`CREATE SCHEMA IF NOT EXISTS`、`Meta.schema`）— 隔离性好的新增代码，易移植
- `common/settings.py`：DB 默认值 `mysql`→`postgres`（2 行）
- `rag/graphrag/search.py`：两个检索函数改成 **async + await get_vector**
- `deepdoc/parser/mineru_parser.py`：+140/−9，**大改动**，官方在 0.26.1 也改了 +18/−6 → 真冲突，需逐行合
- `rag/app/paper.py`：`sections` 空值防御
- `conf/llm_factories.json`：新增 `qwen3.5-397b-a17b` 模型条目

### C 类 — 纯新增文件（零冲突）
- `docker/init_postgres.sql`、`docker/init/fix-gai.sh`：官方无此文件，直接带过去即可

## 三、关键发现 ⚠️

对 `rag/graphrag/search.py` 的 async 改造**不是多余的，反而修了官方的 bug**：

在 v0.26.1 里，`get_vector` 已经是 `async def`（search.py:53），但 `get_relevant_ents_by_keywords` / `get_relevant_relations_by_txt` **仍是同步函数，且调用 `get_vector` 时没有 `await`**（search.py:121/132）——这会拿到一个未 await 的 coroutine 而非向量。本 fork 正好修复了这个问题，**此改动必须保留并重新应用到 0.26.1 上**。

## 四、执行步骤

### 准备
```bash
git fetch origin --tags
git branch backup/main-pre0.26.1 main          # 备份，随时可回退
git checkout -b upgrade/0.26.1 v0.26.1
```

### 步骤 1 — 零冲突新增文件（C 类）
```bash
git checkout main -- docker/init_postgres.sql docker/init/fix-gai.sh
```
> 验证 `init_postgres.sql` 里建的 schema 名与 `.env` 的 `POSTGRES_SCHEMA=rag_flow` 一致。

### 步骤 2 — 代码逻辑（B 类，逐文件三方合并，建议拆成 2~3 个提交）

| 文件 | 操作要点 | 风险 |
|---|---|---|
| `common/settings.py` | 2 处 `"mysql"`→`"postgres"` | 低 |
| `api/db/db_models.py` | 移植 schema 支持：`pop("schema")`+`search_path`、`DB_SCHEMA`、`Meta.schema`、`CREATE SCHEMA IF NOT EXISTS` | 低（新增为主，注意官方此处有无改动） |
| `rag/graphrag/search.py` | 两函数改 `async def` + `await get_vector` + 调用处加 `await`。**修官方 0.26.1 的漏 await bug，必须保留** | 中 |
| `rag/app/paper.py` | `sections` 空值防御提前 return | 低 |
| `conf/llm_factories.json` | 在 dashscope 节点加 `qwen3.5-397b-a17b` | 低 |
| `deepdoc/parser/mineru_parser.py` | **最难**：本地 +140/−9，官方 +18/−6。先 `git diff 8f0632c8d v0.26.1 -- 该文件` 看懂官方改了什么，再逐 hunk 合 | **高** |

### 步骤 3 — 部署配置（A 类，基于 0.26.1 新版重放，勿整文件覆盖）
官方在 0.26.1 可能新增了配置项，**必须以 0.26.1 为底**叠加定制：
- `docker/.env` / `web/.env`：端口 6100-6106、`DB_TYPE=postgres`、postgres 连接项、`EMBEDDING_BATCH_SIZE=5`、`GRAPH_EMBEDDING_CONCURRENCY=2`、`RAGFLOW_IMAGE` 本地镜像
- `conf/service_conf.yaml` / `service_conf.yaml.template`：postgres 配置块（注释掉 mysql）
- `docker/docker-compose.yml` / `docker-compose-base.yml`：postgres 服务 + 端口映射
- `Dockerfile` / `.dockerignore` / `.gitignore` / `docker/entrypoint.sh` / `download_deps.py`：本地构建相关

### 步骤 4 — 依赖锁
```bash
rm -f uv.lock && uv lock        # 丢弃旧 lock，从 0.26.1 pyproject 重新生成（切勿沿用旧 uv.lock）
```

### 步骤 5 — 验证
1. `docker compose -f docker/docker-compose-base.yml up -d` 起依赖（含 postgres）
2. 启动后端，确认 PostgreSQL **schema 自动创建** + 建表落在 `rag_flow` schema
3. GraphRAG 检索冒烟测试（验证 async 改造）
4. MinerU 解析一篇文档（验证步骤 2 的高风险合并）

## 五、高风险点（需重点 review）
1. `deepdoc/parser/mineru_parser.py` —— 双方大改，唯一真冲突的代码文件
2. `rag/graphrag/search.py` —— async 改造涉及调用链一致性

## 六、回退
```bash
git checkout main
git branch -D upgrade/0.26.1
# 备份分支 backup/main-pre0.26.1 始终保留
```
