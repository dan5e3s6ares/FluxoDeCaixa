# 6. README — Estrutura para o Repositório GitHub

> Este documento é a **fonte no MCP**; o Executor deve espelhar no `README.md` do repositório.
> Especificações detalhadas: documentos **01–05** e **07** no Helper AI MCP (ver [08 - Índice de Documentação MCP](08-indice-documentacao)).

## Visão Geral da Solução

Sistema de **fluxo de caixa** multi-tenant para **comerciantes** (`merchant_id`): registro de débitos/créditos com **data de competência** e consulta de **saldo diário consolidado**. Arquitetura em **três microserviços** desacoplados por eventos (**NATS JetStream**), integração **Transactional Outbox**, exposição via **KrakenD** com autenticação **Keycloak (OIDC)**, execução em **Kubernetes (K3s)** com deploy local via **kubectl/kustomize** e observabilidade **OpenTelemetry**.

| Bounded context | Serviço | Responsabilidade |
|-----------------|---------|------------------|
| Gestão de Lançamentos | `svc-lancamentos` | Write path, idempotência, outbox |
| Consolidação Diária | `svc-consolidado` | Consumer de eventos, projeção materializada (write-side do read model) |
| Consulta de Saldo | `svc-consulta` | Read path em pico (50 req/s), Redis + PG consolidado; desacoplado da consolidação |

> **Nota:** `svc-consulta` atende `GET /api/v1/consolidado/*` no hot path; padrão de acesso à projeção (réplica read-only vs API interna) — doc **04** e discussões no doc **01**.

## Justificativa das Escolhas de Arquitetura

| Pilar | Decisão | Por quê | Trade-off / compensação |
|-------|---------|---------|-------------------------|
| **Resiliência** | DB e deploy separados; eventos assíncronos + Outbox | Lançamentos permanecem disponíveis mesmo com consolidado down | Consistência eventual no saldo (lag ≤ 60s p95) |
| **Escalabilidade** | HPA no consolidado + Redis | Atende 50 req/s com ≤5% de falha em pico | Complexidade de cache invalidation |
| **Segurança** | Keycloak + JWT (`merchant_id`) + idempotência | Protege dados financeiros multi-tenant | Dependência crítica do IdP |
| **Operabilidade** | `make start` sobe VM/K8s inteiro | Requisito de plataforma | Curva de aprendizado (K3s, podman, kustomize) |
| **Desacoplamento** | Três microserviços + mensageria | Isolamento de falha e deploy independente no read/write | Mais componentes que monólito modular |
| **Gateway** | KrakenD (JWT, rate limit, schema) | Superfície única HTTPS | Latência adicional (~ms) no hot path |

## Requisitos de Serviço (SLR — resumo)

| Métrica | Meta (MVP) |
|---------|------------|
| Pico leitura consolidado | **50 req/s** (burst 5 min) |
| Sucesso em pico | **≥ 95%** (≤ 5% 5xx/timeout > 2s) |
| Lag consistência eventual | **≤ 60s** (95% das leituras após último evento) |
| Latência p99 GET consolidado | **< 500 ms** |
| Propagação lançamento → saldo | **p95 < 5s** |
| SLA write (lançamentos) | **99.9%** com consolidado indisponível |

Detalhamento: documento **01 - Contextualização** e **02 - Requisitos e Domínios**.

## Glossário de Domínio (mínimo)

| Termo | Definição |
|-------|-----------|
| **Lançamento** | Movimento financeiro (débito/crédito) com valor, tipo e data de competência |
| **Data de competência** | Dia civil do evento financeiro — **chave** da consolidação diária |
| **Consolidado diário** | Projeção materializada: saldo, totais de crédito/débito por `merchant_id` + data |
| **Comerciante** | Tenant identificado por `merchant_id` (claim JWT) |
| **Outbox** | Registro na mesma transação do lançamento; publicação assíncrona no NATS |

Modelo completo: documento **02 - Requisitos e Domínios**.

## Estrutura de Repositório (monorepo — decisão fechada)

**Monorepo** com `services/lancamentos`, `services/consolidado` e `services/consulta`. Imagens locais `fluxo-caixa/{svc}:dev` — build com **podman** (`scripts/build-images.sh`) e import para o containerd do k3s; deploy via **kubectl apply -k** (`deploy/k8s/overlays/dev` ou `prod`).

```
/
├── Makefile                 # make start | stop | test | test-e2e | clean
├── README.md
├── docs/                    # espelho opcional dos docs MCP
├── scripts/                 # bootstrap, cluster, build, deploy, health
├── deploy/
│   ├── k8s/                 # manifests / kustomize
│   ├── krakend/
│   └── keycloak/
├── platform/
│   ├── otel/
│   └── nats/
├── services/
│   ├── lancamentos/
│   │   ├── app/
│   │   ├── tests/
│   │   └── pyproject.toml
│   ├── consolidado/
│   │   ├── app/
│   │   ├── tests/
│   │   └── pyproject.toml
│   └── consulta/
│       ├── app/
│       ├── tests/
│       └── pyproject.toml
```

## Pré-requisitos e `make start`

| Requisito | Versão / nota |
|-----------|----------------|
| VM Linux | Recursos: ≥ 8 GB RAM, 4 vCPU (dev) |
| Podman | Build local de imagens e import no k3s containerd |
| K3s | Cluster padrão (`CLUSTER_TYPE=k3s`) |
| uv | Python 3.12+ por serviço |
| kubectl, helm | Operar cluster |

```bash
make start          # idempotente: bootstrap → cluster-up → build → deploy-platform → deploy-apps → wait-healthy
make build          # podman build fluxo-caixa/{svc}:dev + k3s ctr import (SVC=lancamentos para um serviço)
make test           # pytest unitário por serviço (uv run)
make test-e2e       # integração via KrakenD (stack up)
make stop           # derruba cluster; preserva PVCs
make clean          # cluster-down --purge-pvc
./scripts/test-podman-nodocker.sh   # valida wiring podman-docker (sem root)
```

Comportamento idempotente, scripts e variáveis (`CLUSTER_TYPE`, `ENV`, `SVC`): documento **07 - Plataforma e Sistema**.

## Estratégia de Testes

| Nível | Comando / local | Escopo |
|-------|-----------------|--------|
| **Unitário** | `make test` | Por serviço isolado (`tests/unit`), via `uv run pytest` |
| **E2E** | `make test-e2e` | APIs via KrakenD com stack completa |
| **Contrato / integração** | CI (fase 2) | Eventos NATS, schemas — doc MCP separado |

Regra de projeto **TDD Required** aplica-se ao desenvolvimento; o README não duplica o ciclo Red/Green/Refactor.

## Contratos de API (referência)

Contratos canônicos nos documentos MCP **02** (RF/RNF) e **05** (validação, JWT, idempotência). Resumo:

| Método | Rota | Descrição |
|--------|------|-----------|
| `POST` | `/api/v1/lancamentos` | Registrar movimento (`Idempotency-Key`, JWT) |
| `GET` | `/api/v1/lancamentos` | Listar com filtros e cursor |
| `GET` | `/api/v1/consolidado/{data}` | Saldo do dia via **svc-consulta** (ISO date); header `X-Consolidado-Stale` se aplicável |

OpenAPI versionada em `/v1/`; erros **RFC 7807**. Gateway valida JSON Schema; serviços validam regras de negócio (Pydantic v2).

## Evoluções Futuras e impacto no MVP

| Evolução | Pré-requisito já no MVP? |
|----------|--------------------------|
| Multi-loja / hierarquia | **Sim** — `merchant_id` em payload, JWT e chaves de consolidação |
| Notificações push (SSE/Webhook) | **Parcial** — KrakenD extensível; canal não implementado |
| Auditoria imutável / event sourcing | **Parcial** — eventos versionados NATS; WORM fora de escopo |
| Conciliação bancária (OFX) | **Não** — adiável |
| Dashboard analítico / DR multi-região | **Não** — adiável |

## Documentação no MCP

| Doc | Conteúdo |
|-----|----------|
| 01 | Contexto, SLR, semântica de datas |
| 02 | Requisitos, modelo de dados |
| 03 | Padrões (Outbox, CQRS, NATS) |
| 04 | Arquitetura alvo, diagramas C4, `svc-consulta` |
| 05 | Segurança, observabilidade |
| 07 | Plataforma, Makefile, K3s, deploy local |
| 08 | Índice completo |
| — | [Simplificação de Projeto](simplificacao-de-projeto) — eliminação CI/CD, deploy local |

Todos os ADRs e especificações detalhadas são documentos filhos de **Desafio Fluxo de Caixa** no Helper AI MCP.

> **Sincronização 2026-05-25:** deploy local podman→k3s (`:dev`), sem CI/GitOps — ver [Simplificação de Projeto](simplificacao-de-projeto). Alinhado aos docs **01–05** e **07** (v5+).
