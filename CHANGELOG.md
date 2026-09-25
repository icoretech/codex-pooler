# Changelog

## [0.9.1](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.9.0...codex-pooler-v0.9.1) (2026-09-25)


### Features

* **admin:** identify DeepSeek Harness in request logs ([d72ec5a](https://github.com/icoretech/codex-pooler/commit/d72ec5a32f96eee4d3f21c7c53d232bab28eef55))


### Bug Fixes

* **gateway:** allow encrypted agent handoffs to leave exhausted accounts ([0e05011](https://github.com/icoretech/codex-pooler/commit/0e0501136fa511356aada5f145c57b11421528bc))
* **gateway:** retry incomplete native HTTP tool output once ([44cc8b5](https://github.com/icoretech/codex-pooler/commit/44cc8b5ff15e9a560a5c846d1ce57a539750f40f))


### Tests

* **admin:** await API key budget loading before assertions ([a95e92c](https://github.com/icoretech/codex-pooler/commit/a95e92cdd59c71878fb7ac775dd8adc9de67573d))
* fence committed pool cleanup behind owner shutdown ([dd10149](https://github.com/icoretech/codex-pooler/commit/dd1014993ef7acdee676f16c661a6586697ab05c))


### Miscellaneous Chores

* **deps:** update dependency openai/codex to v0.157.0 ([cf3071f](https://github.com/icoretech/codex-pooler/commit/cf3071f22ba43aacfac5416d294c8c8667e868a6))
* **deps:** update docs and frontend dependencies ([a7a5f5f](https://github.com/icoretech/codex-pooler/commit/a7a5f5f52d5eea70cfc50901bd4baa8a709b2a99))

## [0.9.0](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.8.6...codex-pooler-v0.9.0) (2026-09-24)


### Features

* **admin:** show a websocket delivery receipt's completed item count and failed write in the request-log drawer ([8088803](https://github.com/icoretech/codex-pooler/commit/8088803a58b70e56d6c327c0aa307eac5c252b55))
* **admin:** show the highest frame class of a websocket delivery receipt in the request-log drawer ([c9ec66f](https://github.com/icoretech/codex-pooler/commit/c9ec66f15674a851d196782a62b07fb9dd9e8e70))
* **alerts:** name bounded assignment state counts in incident detail and delivery summaries ([1843ef4](https://github.com/icoretech/codex-pooler/commit/1843ef4e705e5ab298389713a687421bc7151e38))
* **catalog:** serve Codex catalog entries without the mirrored base_instructions to clients that read the instructions template ([cc8dff5](https://github.com/icoretech/codex-pooler/commit/cc8dff51c349f804c161238b34836cd901c0ed19))
* **dev:** add mix dev.pool_serving_override to set a model's Full/Lite mode on a named Pool ([c907b31](https://github.com/icoretech/codex-pooler/commit/c907b3127c5a1a76240e03b16398ab3aa013c2cd))
* **dev:** enqueue the Pool catalog sync after a bundle import with --sync-catalog ([94476da](https://github.com/icoretech/codex-pooler/commit/94476da85faff80ed60c5fd33b93ad2c904cb84e))
* **dev:** let fixtures target an explicit loopback database and an in-cluster fake upstream ([75fa81f](https://github.com/icoretech/codex-pooler/commit/75fa81f85b0e7518528171802a37b83002e292c2))
* **dev:** point seeded synthetic identities at a configurable fake and seed a dedicated real-traffic Pool ([adc5601](https://github.com/icoretech/codex-pooler/commit/adc560127eabea00a91b5e786ed329f61062445a))
* **jobs:** log one bounded warning line for every failed or discarded Oban job ([395c007](https://github.com/icoretech/codex-pooler/commit/395c007187cbe72a01cd31903567533df6d9b2a9))
* **quota:** delete account quota windows whose reset passed more than 30 days ago in runtime state cleanup ([718e3c1](https://github.com/icoretech/codex-pooler/commit/718e3c1670d2e8e82273b28c2ae33bab6d124f17))
* **telemetry:** count native compaction admission clears by reason, stage and topology ([79649fc](https://github.com/icoretech/codex-pooler/commit/79649fc4193643430409773f93c5f853cd8b2e8d))
* **upstreams:** let an operator clear a provider-requested usage polling pause, audited ([d75061f](https://github.com/icoretech/codex-pooler/commit/d75061f90fe615c9ac0e37968fef828acf9f4c39))
* **upstreams:** log a warning when a provider Retry-After pauses usage polling for over an hour ([70baa9a](https://github.com/icoretech/codex-pooler/commit/70baa9aa1e551cd37f73f4b2a5ac4b1472b08301))
* **upstreams:** show a provider-requested usage polling pause on the admin account card ([18fe999](https://github.com/icoretech/codex-pooler/commit/18fe999dd4a2ac8bf02136bfa14e4c2197343135))
* **upstreams:** show the usage polling pause notice in the upstream cockpit ([52ffa91](https://github.com/icoretech/codex-pooler/commit/52ffa9118223c15649ec4b3f7640149c9628e872))
* **websocket:** log how long a socket session cleanup that outlived the socket's 100 ms wait took, under the socket's request id ([c49818a](https://github.com/icoretech/codex-pooler/commit/c49818af45fb23497471b1482b93386e8d77d99b))
* **websocket:** log why an upstream websocket connection closed between requests ([153f69a](https://github.com/icoretech/codex-pooler/commit/153f69a1c67e316103b99f5513e09985f9b786ee))


### Bug Fixes

* **access:** advance an API key's runtime epoch when an edit changes a policy field its open websockets read at the upgrade ([220eb34](https://github.com/icoretech/codex-pooler/commit/220eb34904feb0a379ecb13dfe54b2361aa5be47))
* **access:** delete an API key with a large history in background batches and audit the delete with it ([8754f45](https://github.com/icoretech/codex-pooler/commit/8754f4532d63b26a0d1f8d35517aeed9549958f3))
* **access:** keep every API key policy field an update omits instead of resetting it to all models, no enforcement and no limit ([1f0d590](https://github.com/icoretech/codex-pooler/commit/1f0d5905055592428c606f76e371766ff0d1a69c))
* **access:** normalize and validate the key-row policy fields Access.update_api_key receives through the policy merge ([9f02de6](https://github.com/icoretech/codex-pooler/commit/9f02de6da89d37d21b76b341fefd4b55db501906))
* **access:** refuse binding limits on the key-row Access.update_api_key path instead of ignoring them ([c002d08](https://github.com/icoretech/codex-pooler/commit/c002d0881669299f6a839e5c62bc3697f05f5d44))
* **accounting:** admit a websocket turn's resend after a provider terminal failure on its turn claim with owner forwarding off ([598d576](https://github.com/icoretech/codex-pooler/commit/598d576c3a70f30454332c4d384be1eb87f8f36c))
* **accounting:** admit the byte-identical resend of a websocket turn interrupted before any visible output ([21b89b6](https://github.com/icoretech/codex-pooler/commit/21b89b6c89d8973a08e201542c86927ab072eafe))
* **accounting:** admit the full resend after a previous_response_not_found refusal whose client closed the socket ([2e43aa8](https://github.com/icoretech/codex-pooler/commit/2e43aa83715d5771dceced91c6c9f39628f3ee05))
* **accounting:** admit the resend of a turn-opening websocket request after a provider stream cut before any completed output ([2d41e41](https://github.com/icoretech/codex-pooler/commit/2d41e41f765572a8f5ad2010cab23b696c6877bc))
* **accounting:** admit the resend of a turn-opening websocket request whose client left before any output ([dcb3704](https://github.com/icoretech/codex-pooler/commit/dcb3704541053fdc9fb4ba5101acb0413d956e74))
* **accounting:** chain a forwarded resend onto a client-retry successor cut before output ([2cb2810](https://github.com/icoretech/codex-pooler/commit/2cb28107bf6335bc494134c435508fc3b217300b))
* **accounting:** close the forwarded chain behind an HTTPS fallback so a later websocket resend is not a second generation ([60da5bc](https://github.com/icoretech/codex-pooler/commit/60da5bcee0c764cc1d7b459bc48ecc1efc0fee4d))
* **accounting:** count a capped key's live requests for max_active_requests instead of reading its whole reservation history ([02ea0d9](https://github.com/icoretech/codex-pooler/commit/02ea0d91f8fecb097c211580a8e2e86d5c908009))
* **accounting:** count pending window tokens from a key's live requests, not every reservation it never released ([c248f07](https://github.com/icoretech/codex-pooler/commit/c248f071d506b641aa6ba529b906da22ae443aad))
* **accounting:** end the reservation limit windows at the key's latest future-dated ledger entry ([329a75f](https://github.com/icoretech/codex-pooler/commit/329a75fd2b494c49634c35e02c212e3fc33bca26))
* **accounting:** give the HTTPS fallback of a native websocket turn the websocket request's resend witness ([f0ed6ca](https://github.com/icoretech/codex-pooler/commit/f0ed6cae3243574ef953c776d512b711d5acdc98))
* **accounting:** hold only the node a turn resend chains onto to the client-retry window ([99f6abb](https://github.com/icoretech/codex-pooler/commit/99f6abb492bc4d9c10f2fdcaa92cbc0105d2a592))
* **accounting:** judge a resend arriving mid-settlement against the turn its settlement writes ([629f111](https://github.com/icoretech/codex-pooler/commit/629f11180fe44a757c429bc5c916055c3697d9ff))
* **accounting:** keep a websocket delivery receipt the socket recorded before the attempt was finalized ([cae4d9a](https://github.com/icoretech/codex-pooler/commit/cae4d9a61c322088c977ac1acad08e8e3a2a9964))
* **accounting:** let a turn-claim resend chain past the chain's own client-retry links ([dc138e5](https://github.com/icoretech/codex-pooler/commit/dc138e59df1c5e7a30ff5884053d0be4349d767e))
* **accounting:** make the request-log model index partial so Pool-only queries cannot pick it ([0be14fa](https://github.com/icoretech/codex-pooler/commit/0be14faaed79c34b5735d75568a0a7252a476839))
* **accounting:** rebuild every recent day whose daily rollup coverage is missing or incomplete ([5bd8574](https://github.com/icoretech/codex-pooler/commit/5bd8574c020d7e70fe58a931b235f0dd172babe4))
* **accounting:** record a second websocket refusal without a turn claim under its own correlation id ([687a8e8](https://github.com/icoretech/codex-pooler/commit/687a8e87716f407f3094f1bca97ff4fed909661a))
* **accounting:** refuse a forwarded resend whose predecessor carries two retry links instead of raising ([dff13ff](https://github.com/icoretech/codex-pooler/commit/dff13ff31980e853a22154d9388228afddce9d22))
* **accounting:** refuse a request whose own estimate exceeds a daily or weekly key token window as a per-request 400, not a 429 with a reset hint ([241d0ac](https://github.com/icoretech/codex-pooler/commit/241d0ac25a79f0657d6f3d6c8da39450c46deb0a))
* **accounting:** report a served native HTTP chain node as the turn's terminal predecessor ([9b1ec34](https://github.com/icoretech/codex-pooler/commit/9b1ec3408565b393fa32988c81992f5525081f5e))
* **accounting:** serve the resend of a completed websocket turn the socket pushed nothing of as one successor ([908a057](https://github.com/icoretech/codex-pooler/commit/908a057193773dbc5b6b8ca0ff5a5666a4edceed))
* **admin:** bound the cockpit recent-event walk to each assignment's newest 10,000 attempts and say so when older attempts were not read ([46e8927](https://github.com/icoretech/codex-pooler/commit/46e8927b9bc6eb1a5d208ccec64ad3cc4abebe74))
* **admin:** carry an API key's stored labels and every model override through the edit form ([2303348](https://github.com/icoretech/codex-pooler/commit/230334884fff072c368e99edc5ed11d1af09a18c))
* **admin:** keep an empty API key operator note empty instead of saving the edit form's No notes placeholder ([e0abe02](https://github.com/icoretech/codex-pooler/commit/e0abe02af7ada2972f4c3198ce89683aebd0cfe2))
* **admin:** patch a Pool or upstream account filter the viewer lost out of the Request logs and Audit logs URLs ([965f7bc](https://github.com/icoretech/codex-pooler/commit/965f7bc87754df92fa796acf41a8eb674e18a839))
* **admin:** patch an incident filter or Pool filter the viewer lost out of the Alerts and Invites URLs ([41ecf79](https://github.com/icoretech/codex-pooler/commit/41ecf79ba498fbcee79153df04e0dd562ab2ccc8))
* **admin:** re-read the request logs, API keys, upstreams, stats, operators, jobs and system pages when the viewer's role or Pools change ([f1b5c31](https://github.com/icoretech/codex-pooler/commit/f1b5c31d7eb9823a2aeef4420a8bbee4cc8133f7))
* **admin:** re-read the upstream cockpit, audit logs, alerts, invites, incidents and settings pages when the viewer's role or Pools change ([cfadb70](https://github.com/icoretech/codex-pooler/commit/cfadb70016e9abee236d89682b2fdad1844b1923))
* **admin:** reactivate a disabled or archived Pool from its card menu ([ec77bda](https://github.com/icoretech/codex-pooler/commit/ec77bdad681dabe6d3fb958ea0bb7b516065b73e))
* **admin:** reload the notification center on an unknown notification message shape instead of crashing the page ([59ce15f](https://github.com/icoretech/codex-pooler/commit/59ce15f2739f2a29ec46e2b05610d220c1a0724d))
* **admin:** reload the notification center on the previous release's bare invalidation message ([a51154a](https://github.com/icoretech/codex-pooler/commit/a51154ae3d73251edb11d4035772ea282e98fef2))
* **admin:** reload the Pools page and its permissions when the viewer's role or visible Pools change ([95d9e09](https://github.com/icoretech/codex-pooler/commit/95d9e09a990bd84b7bd92464ec9b3da6ff70502b))
* **admin:** show a requested priority tier echoed as default as priced at priority in request logs ([d49ddc5](https://github.com/icoretech/codex-pooler/commit/d49ddc5c957ec03bcd85de19ef007f1943a2106a))
* **admin:** show the reset a terminal usage-limit answer advised in the request-log list and drawer ([cc4e054](https://github.com/icoretech/codex-pooler/commit/cc4e054f7223896630f4fb6adebba766e52c251c))
* **alerts:** alert once for every new banked saved reset instead of once per upstream identity ([5ba25a7](https://github.com/icoretech/codex-pooler/commit/5ba25a7c5b303b7a40c2e219bfa0ac2af4a8e318))
* **alerts:** carry notification center invalidations over the postgres relay ([054cc70](https://github.com/icoretech/codex-pooler/commit/054cc70d48ed691da8f7fcf7cb7f3a4da65f97a7))
* **alerts:** invalidate an operator's notification centers when their Pool assignments or role change ([2409a42](https://github.com/icoretech/codex-pooler/commit/2409a42e7d2ebfc6c1e019674b663af489d3aa1c))
* **alerts:** invalidate notification centers on a Pool status change and resubscribe them to the Pools their viewer can see ([6d80cd3](https://github.com/icoretech/codex-pooler/commit/6d80cd31a73f231bcc67ae6439de6f271310ff32))
* **alerts:** invalidate the notification centers of the Pools a rule or Pool delete cascades incident targets from ([aedcb13](https://github.com/icoretech/codex-pooler/commit/aedcb1375c1044e7c5c36f56cf069121557ee426))
* **alerts:** judge unscoped quota-state rules by served models and report model_not_served for an unserved rule model ([a770be6](https://github.com/icoretech/codex-pooler/commit/a770be6740e919aebda645adeea2a67b60286d84))
* **alerts:** keep the notification center's subscribed Pools as a sorted id list so dialyzer accepts the subscription diff ([2f99fb3](https://github.com/icoretech/codex-pooler/commit/2f99fb32d5d2c90e78a103fdf07a977c572cfc1d))
* **alerts:** reload a notification center once per incident invalidation across shared pools ([7360fe7](https://github.com/icoretech/codex-pooler/commit/7360fe7a76eabccf4636366e52dc658d83ef1111))
* **alerts:** resolve incidents left with no rule target on the scheduled evaluation pass ([dc4b2bd](https://github.com/icoretech/codex-pooler/commit/dc4b2bd30624b0bb379527fe2424b0e9f225321d))
* **alerts:** scope unscoped quota threshold rules to served models and keep unserved-model thresholds clear ([92e0c39](https://github.com/icoretech/codex-pooler/commit/92e0c39e4ac51cf1dc58e6f331b24e1782b90309))
* **alerts:** subscribe the owners' open notification centers to a Pool created while they are open ([b25b93f](https://github.com/icoretech/codex-pooler/commit/b25b93fd46ef3961461a6c4d0c099bd5e914f6d0))
* **audit:** audit each upstream account the Pool editor assigns or unassigns ([1a3f2f3](https://github.com/icoretech/codex-pooler/commit/1a3f2f3972f21a4ba9fd2c1f2931074191de6bf4))
* **audit:** count audit events at most 10,000 rows past the offset on the Audit logs page and the MCP list tool ([f123cee](https://github.com/icoretech/codex-pooler/commit/f123cee4a3a8b4ea9bd47ee665ac25087b27c799))
* **bridge:** answer a pre-output provider usage limit on a bridged /v1 stream as its HTTP twin, failover included ([f6a886e](https://github.com/icoretech/codex-pooler/commit/f6a886e02f1d5921fc1092204efbd1e7cecb7d04))
* **catalog:** leave out a served Codex model entry the requesting client cannot decode instead of letting it discard the whole Pool catalog ([ff0fb58](https://github.com/icoretech/codex-pooler/commit/ff0fb58addd8d741db108238341a4c2f1465567d))
* **catalog:** select a catalog representation from a User-Agent only when it is a Codex build's ([08bde33](https://github.com/icoretech/codex-pooler/commit/08bde33e7f1b5df3eb792f555dc1355dfc418d83))
* **catalog:** select the served catalog representation from the request User-Agent on /models as on every turn ([96e6d88](https://github.com/icoretech/codex-pooler/commit/96e6d88d16e3e27c5b94628844d5d0c93d4a0a41))
* **continuity:** take an expired, unrenewed HTTP session lease over at the synchronous renewal and record owner refusals ([6cd9164](https://github.com/icoretech/codex-pooler/commit/6cd9164cac3371b7a659d1e8292b7da6c8418201))
* **deps:** update dependency daisyui to v5.7.43 ([#427](https://github.com/icoretech/codex-pooler/issues/427)) ([5a29f78](https://github.com/icoretech/codex-pooler/commit/5a29f786aba90db625515a7ee4cc71e8ffbb46e2))
* **dev:** accept the optional upstream base URL in the full seed's run contract ([87e47af](https://github.com/icoretech/codex-pooler/commit/87e47af191570154c4704a3f93e710f18c3087c8))
* **dev:** close the run key's unredeemed replay entitlements before the compaction fixture releases ([07c0aca](https://github.com/icoretech/codex-pooler/commit/07c0acaef3d90f4983b7e3e28b283a4453ae553d))
* **dev:** declare the provider's Fast tier on the full seed's gpt-6 source assignments ([ea04495](https://github.com/icoretech/codex-pooler/commit/ea04495346ce00e523a24f9df033d968b858a586))
* **dev:** declare the provider's service tiers on the Codex compaction fixture model ([00517c6](https://github.com/icoretech/codex-pooler/commit/00517c6892e7433bb9a66930600b49f9c5a0bda2))
* **dev:** declare the provider's service tiers on the OpenAI v1 fixture's gpt-6 text models ([ec91840](https://github.com/icoretech/codex-pooler/commit/ec91840a9762545a2856c258b9cb7d6d5eafed15))
* **dev:** disable background jobs before mix dev.mcp_fixture boots the application ([81450e1](https://github.com/icoretech/codex-pooler/commit/81450e18fd39eff39eb459fa5b518e9c8dfda00f))
* **dev:** disable background jobs before the fixture and seed tasks boot the application ([c6b02c1](https://github.com/icoretech/codex-pooler/commit/c6b02c18b8b25eb54e5e31720fc60ee4b5c10425))
* **dev:** import upstream account bundles as access-token-only copies by default ([12dc83d](https://github.com/icoretech/codex-pooler/commit/12dc83d7e394ef3fdba80399dc2cc7f277cca38f))
* **dev:** let the QA phase supervisor end the phase from the cap marker so a TERM the wrapper never acts on cannot defeat the cap ([ff2057a](https://github.com/icoretech/codex-pooler/commit/ff2057ac007863d28773e7512ad295cfce9332b6))
* **dev:** name the model slug in the perf seed's per-source metadata so its Pool routes ([2ab525a](https://github.com/icoretech/codex-pooler/commit/2ab525acfad94e3e79f91c855604ade275283e78))
* **dev:** repeat the QA phase cancellation TERM until the supervisor has exited ([80ee3ca](https://github.com/icoretech/codex-pooler/commit/80ee3cac4eac8644fe6507bb2a2bdcd840485e8d))
* **dev:** seed the full profile's expiry fixtures with an access token only ([7377f6c](https://github.com/icoretech/codex-pooler/commit/7377f6c079351402443546c725668ccef23f21ca))
* **dev:** serve a Codex-decodable model entry from the compaction smoke fixture Pool ([7c79aa8](https://github.com/icoretech/codex-pooler/commit/7c79aa86d2c110c7d7020f979589b40405d267ff))
* **dev:** serve the OpenAI V1 fixture catalog as entries the released Codex client decodes ([d6013b3](https://github.com/icoretech/codex-pooler/commit/d6013b39626a73a3a41429afd08c0f7d05b547c6))
* **dev:** watch only this checkout's web, asset and translation directories for live reload ([1915204](https://github.com/icoretech/codex-pooler/commit/19152044a5a3a2fed5e50be0a26e7714e46115ba))
* **events:** deliver relayed pool and status notifications once per node ([15f20e2](https://github.com/icoretech/codex-pooler/commit/15f20e28e4141d9b5ee29b2fc527bee82650176e))
* **events:** listen again when the postgres notifications process restarts ([2bc7263](https://github.com/icoretech/codex-pooler/commit/2bc726329192f2a1a7d49e22966c5dced2b28e2f))
* **events:** skip a postgres notification whose relay raises instead of exiting the bridge ([225c03c](https://github.com/icoretech/codex-pooler/commit/225c03ca493a64662adf108625ae76bb02a77041))
* **finalization:** advise the Pool's soonest return on a relayed provider usage-limit 429 ([2dea067](https://github.com/icoretech/codex-pooler/commit/2dea0673d3cc4ce19d445e457cf9367831c956ae))
* **finalization:** answer a provider usage-limit 429 on the last candidate with the terminal usage_limit_reached and its reset ([1a8c2bd](https://github.com/icoretech/codex-pooler/commit/1a8c2bd46fa2f32eaf88939354b1f42a2258d584))
* **finalization:** answer a relayed native 429 with the tokens the released client classifies it by ([11fbb59](https://github.com/icoretech/codex-pooler/commit/11fbb59f13f0a4be88f07927c515170f53cfa29c))
* **finalization:** read the invalid previous_response_id message at runtime so Metadata keeps no compile-time dependency on ErrorCodes ([e1d7b99](https://github.com/icoretech/codex-pooler/commit/e1d7b9920ce48affefb2f6ee7af62d4fa401813a))
* **finalization:** record a provider usage-limit 429 as the account's quota denial and keep it out of route health ([3dc8cfa](https://github.com/icoretech/codex-pooler/commit/3dc8cfa6e547dbe0ada79cc3801c0310fad28bec))
* **finalization:** relay the provider's unsupported-parameter detail body as unsupported_parameter with its param ([fa9cdb4](https://github.com/icoretech/codex-pooler/commit/fa9cdb4fd74dd3b996e52f41cfa2b714dc761d48))
* **finalization:** send Retry-After with a relayed native 429 that names its reset ([be73365](https://github.com/icoretech/codex-pooler/commit/be7336566ccbc614bf476d1efbca6352497c4705))
* **gateway:** accept native websocket turn metadata up to 256 KiB so a client's tool inventory does not refuse its turns ([cad028c](https://github.com/icoretech/codex-pooler/commit/cad028cf5abd777d9f6ccb266ea3330e957aa604))
* **gateway:** acknowledge a delivered local owner turn as completed when its completion arrives during socket termination ([ff70790](https://github.com/icoretech/codex-pooler/commit/ff707907874d29927395f25b7d052a7545b6ec24))
* **gateway:** admit the Codex 0.156.0 post_turn compaction phase on the native websocket ([aa7c50b](https://github.com/icoretech/codex-pooler/commit/aa7c50bba48149f6862e9c95d230381953bca456))
* **gateway:** align the compaction resend terminal codes with the Codex 0.156.0 retry classification ([3754d56](https://github.com/icoretech/codex-pooler/commit/3754d564fdbd15e10e61dfca650b5d67f4db770b))
* **gateway:** answer a final native HTTP provider 4xx refusal as the Pooler-authored 400 naming its status ([9e1aab2](https://github.com/icoretech/codex-pooler/commit/9e1aab25d1d11df834ccec286eb1b7bf0531f77c))
* **gateway:** answer a key policy denial no resend can pass, model_not_allowed and the per-request estimate caps, 400 invalid_request_error instead of 403 ([7807e3d](https://github.com/icoretech/codex-pooler/commit/7807e3ddc27ec4cbbebf80c518ba846c17f536ef))
* **gateway:** answer a native non-relayable provider 400 with the Pooler-authored refusal error instead of an empty body ([c1d159a](https://github.com/icoretech/codex-pooler/commit/c1d159a734f2b24a70a7272caa8339f3fd7ef777))
* **gateway:** answer a native non-streaming validation rejection with the Pooler error and relay a Chat input path as messages ([8ac695e](https://github.com/icoretech/codex-pooler/commit/8ac695ec1fac34788faf30546058c99ba68ddb01))
* **gateway:** answer a provider 4xx refusal on the websocket-bridged /v1 stream like the HTTP path ([e8e7e66](https://github.com/icoretech/codex-pooler/commit/e8e7e66cd8396342fff2c0523175b0f6e33abde8))
* **gateway:** answer a transient database failure before dispatch with a retryable 503 ([8bdbb04](https://github.com/icoretech/codex-pooler/commit/8bdbb04a144f33aff6b595a94ab71ed09f8d5b7d))
* **gateway:** answer a transient database failure in request preparation, the websocket turn claim and the replay intent with a retryable 503 ([44b7e29](https://github.com/icoretech/codex-pooler/commit/44b7e2958365a3090a4731947b152c1b4469399d))
* **gateway:** answer an API key policy window refusal 429 with its retry hint and a per-request cap 403 on every transport, and give a forwarded retry successor the same refusal ([5e1bc65](https://github.com/icoretech/codex-pooler/commit/5e1bc653601041cadbd01b660652533c34282953))
* **gateway:** answer the HTTP resend of an HTTP turn refused with a validation 400 with that refusal instead of dispatching it again ([cbb965a](https://github.com/icoretech/codex-pooler/commit/cbb965abe0694064691fe6df9cb64338bfd2d07b))
* **gateway:** answer the HTTPS resend of a finally refused websocket turn with its refusal before reserving ([12df91d](https://github.com/icoretech/codex-pooler/commit/12df91d2deb3a6518952cd6e341e8f08e7e4378e))
* **gateway:** arm a pre-visible owner turn's replay before the closing socket drains its response tasks ([e019949](https://github.com/icoretech/codex-pooler/commit/e0199496e6eb8ea3f78ef797dadd62ed5b02c8fe))
* **gateway:** cap the websocket owner's lease renewal at a third of the ttl and bound the renewal setting by it ([7802acb](https://github.com/icoretech/codex-pooler/commit/7802acb75d83fb613ee3c787836fcc8b4120c627))
* **gateway:** classify a response.incomplete naming a spend or credit limit as a failed turn ([071589e](https://github.com/icoretech/codex-pooler/commit/071589e99e2ea0d107601113009d309add5920ad))
* **gateway:** clear an admitted compaction once when its reservation loses the database ([ab5aea0](https://github.com/icoretech/codex-pooler/commit/ab5aea020a6ba6dc6d290d386ec52c6d8023b12c))
* **gateway:** close reconnectable Codex sessions retired past the expired-alias retention in runtime cleanup ([4aad9ba](https://github.com/icoretech/codex-pooler/commit/4aad9ba5767fa4efe4661cf84f931332e73f4cb2))
* **gateway:** derive the owner's own turn descriptor under the thread claim scope and refuse replay controls against it ([443077c](https://github.com/icoretech/codex-pooler/commit/443077c5afd1cba16c0a420b9a5b11b530fc16fb))
* **gateway:** derive the provider session-id from prompt_cache_key on native HTTP routes when the client sends none ([2bb8d34](https://github.com/icoretech/codex-pooler/commit/2bb8d34b32a6761c2e296849f9dbb5ac70b2eb67))
* **gateway:** derive the provider session-id from the local continuity alias on native HTTP routes when there is no prompt_cache_key ([43e2067](https://github.com/icoretech/codex-pooler/commit/43e206779a2c9b1746644c610e37519b884ff0a0))
* **gateway:** drop a call item's own call_id used as its id from a replayed /v1 Responses input item ([9ac037d](https://github.com/icoretech/codex-pooler/commit/9ac037d174628e634ed9b49069bafcf42201f3a8))
* **gateway:** fence a bridged /v1 turn's continuity by the owner lease it took over ([431f06a](https://github.com/icoretech/codex-pooler/commit/431f06a13b7f48dfbe0b42d0a729898f89c03ba7))
* **gateway:** keep a remote owner's native compaction admission refusal instead of reporting a crash ([6d90f0c](https://github.com/icoretech/codex-pooler/commit/6d90f0cac2934bf3870a49b7aa1d71e5561eb3b0))
* **gateway:** keep websocket terminals refused with invalid_value, invalid_type or string_above_max_length health-neutral ([abeeaa2](https://github.com/icoretech/codex-pooler/commit/abeeaa274b68dfb926408f115dc02326c117a6ee))
* **gateway:** label the owner's native compaction admission clear on client detach and cancel ([c695f65](https://github.com/icoretech/codex-pooler/commit/c695f656b4765a8667ee7008af142eaaef37dd73))
* **gateway:** log a refused reconnect socket's no-op owner-detach cleanup at info ([67a5b3d](https://github.com/icoretech/codex-pooler/commit/67a5b3dd107cc90a905cae217b4c417bc1a4cb24))
* **gateway:** make a resume admitted by the native compaction runtime proof hold its durable resume claim ([946a986](https://github.com/icoretech/codex-pooler/commit/946a9861a772396c1378f4d3b6596b5fe99dcc8a))
* **gateway:** name the bounded reason on the continuity registration failure line ([fef99f0](https://github.com/icoretech/codex-pooler/commit/fef99f008e1cc0aee9b9b3c8ad791f4520331b79))
* **gateway:** name the cause of every direct upstream session native compaction admission clear ([a98895c](https://github.com/icoretech/codex-pooler/commit/a98895cd8d02cb747c8d9401f2fd234e6f63ae68))
* **gateway:** name the cause of every owner-side native compaction admission clear ([b78abb4](https://github.com/icoretech/codex-pooler/commit/b78abb4bdc4090ed8690e9fd69d96b244553b341))
* **gateway:** name the code the client received on the owner websocket replay rejection line ([a4e72b3](https://github.com/icoretech/codex-pooler/commit/a4e72b3aa7affd07c4c517215f44d3df70679164))
* **gateway:** pin an input_image file_id the Pool bridged to the assignment holding the file ([062cb31](https://github.com/icoretech/codex-pooler/commit/062cb313ffbc879e86d6c918702643fa171dd084))
* **gateway:** re-key a steered turn request only when it is further along the turn than the claim's holder ([c9c1cb3](https://github.com/icoretech/codex-pooler/commit/c9c1cb3e9f7af0661596fd146f6ec858106ea71d))
* **gateway:** read the remote admission refusal vocabulary from NativeCompactionAdmission instead of a forwarder copy ([08043bb](https://github.com/icoretech/codex-pooler/commit/08043bb1405edf0b4e8b97bb8018fece96d4a771))
* **gateway:** read the websocket rejection terminal frame without a clause dialyzer proves unreachable ([852e259](https://github.com/icoretech/codex-pooler/commit/852e259b3c5e6cbd594f793d07a25bc698a4de40))
* **gateway:** record a route failure for an HTTP 5xx or 429 on the last candidate and the compact route ([069f0ba](https://github.com/icoretech/codex-pooler/commit/069f0baeb7a0985270b10d10ee4460c854887329))
* **gateway:** record a terminating socket's delivery receipt where the task takes its acknowledgement ([eff6416](https://github.com/icoretech/codex-pooler/commit/eff6416a04c531749ce860da13b079130b3fed52))
* **gateway:** record one downstream delivery receipt per response task when a socket terminates ([b05c880](https://github.com/icoretech/codex-pooler/commit/b05c880000afbe02ca1e67cbca1b23ab6b39d2c7))
* **gateway:** record provider rejection fields on native websocket attempts refused with a wrapped 4xx ([4f401d1](https://github.com/icoretech/codex-pooler/commit/4f401d1565647bd2656a5b4c89bf4251c3611da5))
* **gateway:** record the reset a terminal usage-limit answer advised on its row and log line ([b7ba9ca](https://github.com/icoretech/codex-pooler/commit/b7ba9ca6139b6be5de9abcdf1d10f16bf2b016f9))
* **gateway:** relay a validation rejection's input index in the client's own positions ([2dc4eaf](https://github.com/icoretech/codex-pooler/commit/2dc4eaf171901a0d3c74d0e29eaedcc2603b5b1f))
* **gateway:** relay only the public Responses event vocabulary on the /v1 Responses SSE stream ([04b9eb4](https://github.com/icoretech/codex-pooler/commit/04b9eb4be4642631a0a796109b96382bc6cef077))
* **gateway:** relay only the public Responses event vocabulary on the public /v1/responses websocket ([6c43dbd](https://github.com/icoretech/codex-pooler/commit/6c43dbd6fb3660ee7ea25820f9094052b8194432))
* **gateway:** release a collected owner delivery without waiting for an owner completion that never follows ([0569951](https://github.com/icoretech/codex-pooler/commit/05699511321ebcc194d5b50051eb9c896ea141f8))
* **gateway:** resolve a half-open circuit probe answered by an HTTP client error instead of leaving it in flight ([6fd441c](https://github.com/icoretech/codex-pooler/commit/6fd441c6e69c1c0c630d87d562a7882e089f0723))
* **gateway:** send a provider 4xx refusal to the public /v1/responses websocket as the HTTP path's error event ([41c7152](https://github.com/icoretech/codex-pooler/commit/41c7152de7e108395fff9eeafa15e3e1891cad9a))
* **gateway:** serve a steered request of a native HTTP turn and chain an identical HTTP compaction resend ([062d830](https://github.com/icoretech/codex-pooler/commit/062d830b04f285dfce1b4842d81e0cbd1045c785))
* **gateway:** serve a steered request of a turn sent as full history on a new websocket or over HTTPS after a websocket opener ([10fd3fa](https://github.com/icoretech/codex-pooler/commit/10fd3faabead1feff6ba70ac9100b1d65f458711))
* **gateway:** serve the released client's resend of a compaction it never completed as one chained successor ([fa55ea1](https://github.com/icoretech/codex-pooler/commit/fa55ea1dcf6a1b68a8602da2d3ce1c795f3b092d))
* **gateway:** stop an owner lease renewal that outlives its budget from disconnecting more pooled connections ([14e39c2](https://github.com/icoretech/codex-pooler/commit/14e39c29462f9d6eed3a3c75a36453a6bb0418ed))
* **instance-settings:** invalidate every role's settings cache through a Postgres NOTIFY ([bdec68e](https://github.com/icoretech/codex-pooler/commit/bdec68ed669c99509ca67da72158fd7dc13d475e))
* **jobs:** announce a failed Pool or API key deletion after Oban writes the job's final state ([42c8b1a](https://github.com/icoretech/codex-pooler/commit/42c8b1a3a583640419885b65a17f58d395b52707))
* **mcp:** count request logs at most 10,000 rows past the offset and say whether the total is exact ([a43d9a3](https://github.com/icoretech/codex-pooler/commit/a43d9a3857d69a0e2b625b2b232a3d99f5449d0f))
* **migrations:** cancel a migration lock wait only while the backend is still in the sampled wait ([078f40b](https://github.com/icoretech/codex-pooler/commit/078f40b6869dafdd3c31a6d740075ceec3ca117e))
* **migrations:** say which blocking-session fields another database role hides instead of printing unknown ([9fb74e7](https://github.com/icoretech/codex-pooler/commit/9fb74e7c7d7fee6e90e019364d619150b1a0a4b5))
* **migrations:** wait out older transactions for concurrent index builds and name the blocking sessions ([aaed8bb](https://github.com/icoretech/codex-pooler/commit/aaed8bb3cb890188f52e921efdefd481a9a138fe))
* **onboarding:** hand out the documented Codex provider config with model_catalog_url and api_key_model_discovery ([1fa1495](https://github.com/icoretech/codex-pooler/commit/1fa1495bbc057fca86713d26454f2e895658c5c7))
* **openai:** accept an input_image file_id in /v1 tool output and a detail on a marked message image ([f0291ed](https://github.com/icoretech/codex-pooler/commit/f0291ed87176e6ce1914b1daf7d7261022b0a9f8))
* **openai:** carry a Chat image_url.detail into the input_image and refuse one outside the provider enum ([0aabb4e](https://github.com/icoretech/codex-pooler/commit/0aabb4e68a87015324290d6fba3b2bf0b024403c))
* **openai:** carry and validate image_url.detail in /v1 role tool items and Cline tool-result images ([dfa51af](https://github.com/icoretech/codex-pooler/commit/dfa51af5631881f324b25bb13ed8895672cbde1c))
* **openai:** carry the image_url parts of a Chat tool message into the function_call_output ([b6f92d1](https://github.com/icoretech/codex-pooler/commit/b6f92d18ac7634f4a2eb2ea660e3dd59d392ba2c))
* **openai:** drop a null detail from a /v1 message input_image as from a tool-output one ([4bd7909](https://github.com/icoretech/codex-pooler/commit/4bd7909b7ee87561d6cd9a07ac3b8ef62588ec6c))
* **openai:** forward a /v1 tool-output input_image detail on Full and refuse one outside the provider enum ([467d93f](https://github.com/icoretech/codex-pooler/commit/467d93f402244dcca8ec4420dc86f40592939843))
* **payloads:** send the declared Lite prefix on a request anchored on a response served in Full ([b0f0ae9](https://github.com/icoretech/codex-pooler/commit/b0f0ae9baaf91650274ca13e7c356914fdd33253))
* **payloads:** send the Lite tools manifest and instructions only on a request that opens the provider context ([def8579](https://github.com/icoretech/codex-pooler/commit/def857935e1817fbae886de36bf42f9f8a69f99e))
* **platform:** stop heartbeat writes that outlive their budget from disconnecting a second pooled connection ([ffd48fb](https://github.com/icoretech/codex-pooler/commit/ffd48fbcd92ea258bfd9e1f0c9df0415fb60e19e))
* **pools:** delete a large archived Pool in background batches and audit the delete in its own transaction ([06c45a7](https://github.com/icoretech/codex-pooler/commit/06c45a7251cc1a3196a40bdbe35322f3ed3b4b8c))
* **pools:** name the deletion worker with a literal so the Pool deletion context has no compile-time dependency on it ([50a4d53](https://github.com/icoretech/codex-pooler/commit/50a4d53d39d6f521d2d9de8a5fc2fcf5e52604e3))
* **pools:** type the deletion request's errors as the atoms and terms it returns so the Pools facade's error mapping type-checks ([5e98003](https://github.com/icoretech/codex-pooler/commit/5e980031e359067a705348ec102e28ae4711432f))
* **pricing:** keep a requested priority tier when the Codex backend echoes default ([ef4bdde](https://github.com/icoretech/codex-pooler/commit/ef4bdde895941fe069ffb5ddb5d33a3b3d7e745b))
* **quota:** drop expired rows from a logical window while a sibling reports a future reset ([3e71e3a](https://github.com/icoretech/codex-pooler/commit/3e71e3a6bdc959674d708ed6285438c5f5df4a25))
* **quota:** ignore quota windows past retention on every read surface so decisions never wait for the prune ([995c3f0](https://github.com/icoretech/codex-pooler/commit/995c3f08af282c8a250cf790aa4cab3b10a3764e))
* **quota:** measure a newer relative claim's countdown against the kept reset in the usage-with-existing-reset merge ([82f2db8](https://github.com/icoretech/codex-pooler/commit/82f2db8c7b7815a10cbaa0ad4279501e6f633c3a))
* **quota:** measure a same-cycle usage poll's countdown against the pinned reset instead of keeping the stored one ([1d39b1d](https://github.com/icoretech/codex-pooler/commit/1d39b1d113e5b658c589ddf45ab22b579fbcad51))
* **quota:** prune expired quota windows whose saved-reset confirmation marker has lapsed ([1199567](https://github.com/icoretech/codex-pooler/commit/1199567d7ad4b439313e984145e7fccce7884215))
* **reconciliation:** count stale and expired priming evidence on the effective quota view ([5e297b5](https://github.com/icoretech/codex-pooler/commit/5e297b5bf1032dbeb17edc68b4b5bdb32b7a3b1a))
* **resets:** let the automatic trigger scan read the confirmed Usage API view the lock reads ([1ce7054](https://github.com/icoretech/codex-pooler/commit/1ce70549a5268e0dd9ae121dacf79f6dea361157))
* **routing:** advise a provider-blocked account's exhausted-window reset and the soonest reset of an all-exhausted Pool ([e5305aa](https://github.com/icoretech/codex-pooler/commit/e5305aa27c170f349f1e05717101d3275ae8f442))
* **routing:** advise a workspace-denied account's earliest fresh reset instead of the marked row's ([c620b1d](https://github.com/icoretech/codex-pooler/commit/c620b1d2610e158a1839bfb4f05b734ca3fa3ac3))
* **routing:** advise Retry-After on circuit refusals raised after route filtering and on the file route ([7325f51](https://github.com/icoretech/codex-pooler/commit/7325f513da6bb65966326c65d4d289d7614c2cb6))
* **routing:** advise Retry-After until the earliest open circuit probes on a Pool's retryable 503 ([2e916fb](https://github.com/icoretech/codex-pooler/commit/2e916fb8eb5be3dfb0c1ca01a6761f21f89d6927))
* **routing:** answer an all-exhausted Pool with the provider's terminal 429 usage_limit_reached and its earliest reset ([978966c](https://github.com/icoretech/codex-pooler/commit/978966c00d948ae63a4a6010f45a2750235b69af))
* **routing:** exclude an account a provider usage-limit refusal names until its reset, whatever the reached type ([cebc53b](https://github.com/icoretech/codex-pooler/commit/cebc53bbf14f7d9ba3b821ac4d681f790697bd64))
* **routing:** exclude an account the provider refused at workspace level from every model and Pool on the first 429 ([9eb90b6](https://github.com/icoretech/codex-pooler/commit/9eb90b6140a2dfd9122852eb9b6ceae69a69bb74))
* **routing:** move a native turn to a held-back partition once when its selected partition runs out on a provider usage limit ([3db85e9](https://github.com/icoretech/codex-pooler/commit/3db85e95dac4050fdbe8b768a26e141fe6f99b3b))
* **routing:** name a blank, oversized or non-string prompt_cache_key in the locality reason instead of prompt_cache_key_absent ([122a956](https://github.com/icoretech/codex-pooler/commit/122a956cee686911b1f53b0c484d12ec33286870))
* **routing:** read the valid canonical assignment ids the pre-dispatch pass always sets, without the unreachable nil fallback dialyzer flags ([0e90cfb](https://github.com/icoretech/codex-pooler/commit/0e90cfb63556dea6c08dc6a89966097b0c899197))
* **routing:** record route_excluded for a prompt_cache_key sent to a route that never seeds locality ([bca7988](https://github.com/icoretech/codex-pooler/commit/bca79889b037477855ea897567acfca038f21ff1))
* **routing:** record websocket_transport as the locality reason of a websocket turn instead of prompt_cache_key_absent ([77188c4](https://github.com/icoretech/codex-pooler/commit/77188c4aca1b748a0c17cad76d626cb20c2b434b))
* **settings:** bound the owner lease ttl by one pre-dispatch statement plus the synchronous renewal ([ebabe3e](https://github.com/icoretech/codex-pooler/commit/ebabe3e9181aa9154b4d19b5ea32d93fe9595083))
* **settings:** drop the unreachable fallback clause of the owner lease renewal clamp log that dialyzer flags ([9e5869d](https://github.com/icoretech/codex-pooler/commit/9e5869d351d7d2bb60e5cf7dfde9d0da285fd1e8))
* **status:** reload the admin status view when a freshness event names a newer revision ([747b0dc](https://github.com/icoretech/codex-pooler/commit/747b0dccd333bafe2a7c05f05a9030e28379c895))
* **streaming:** announce a withheld SSE preamble to the Codex idle timer with one keepalive data event ([dcee0c6](https://github.com/icoretech/codex-pooler/commit/dcee0c6e80ae17830d32501fe3cbe0627dcc1cbe))
* **streaming:** frame a multi-line upstream websocket text as one SSE event on the HTTP SSE bridge ([fe1ef8e](https://github.com/icoretech/codex-pooler/commit/fe1ef8e17a2d84e1e732274b6c51f14f63fb81dd))
* **streaming:** stamp a native HTTP turn visible on the first output it shows the client, not on a withheld preamble ([e28d369](https://github.com/icoretech/codex-pooler/commit/e28d369106c2111e6d1683bb2b5746f726fb65a7))
* **upstreams:** scope the usage polling pause to the provider account instead of the credential epoch ([41c4aad](https://github.com/icoretech/codex-pooler/commit/41c4aade05852c592790c816c12ec7169541cae3))
* **v1:** answer an anchored /v1/responses request that cannot reach its producing connection with previous_response_not_found ([deddcc2](https://github.com/icoretech/codex-pooler/commit/deddcc2b7bc6de7f05ededec3288574df8eee7b8))
* **v1:** type a redacted upstream 429 as rate_limit_error instead of server_error ([1696532](https://github.com/icoretech/codex-pooler/commit/1696532854ecfe0b4b6e5054e6a764d931f05318))
* **v1:** type a redacted upstream 4xx refusal as invalid_request_error instead of server_error ([52d6bc4](https://github.com/icoretech/codex-pooler/commit/52d6bc4c5175b482382003dc1cdbbcd84195bd50))
* **v1:** type the masked public websocket failure of a provider 429 as rate_limit_error ([86c1d60](https://github.com/icoretech/codex-pooler/commit/86c1d6081f4ec46f7b688f7c16056432e322c1db))
* **web:** choose the dev dashboard routes at compile time so dev Dialyzer stays clean ([8405ce6](https://github.com/icoretech/codex-pooler/commit/8405ce6d812051458e3585fbd44a47298ace962d))
* **websocket:** admit the released client's anchored pre-turn compaction under the admission its previous turn armed instead of refusing it 503 ([e48cde2](https://github.com/icoretech/codex-pooler/commit/e48cde2f99edb3d90d1f2d000465fa243d806aa8))
* **websocket:** answer a closing socket's early owner detach without waiting for an owner still starting its upstream ([c00ebff](https://github.com/icoretech/codex-pooler/commit/c00ebff5dfec43e34587f75d003d256d5efcdbea))
* **websocket:** answer a deferred final compaction turn on the active-turn reconnect route through the ordinary owner preflight instead of refusing it 503 ([280c0f3](https://github.com/icoretech/codex-pooler/commit/280c0f3fe7850233eeca3bfef9237ebf51695ce6))
* **websocket:** answer a finally refused turn's resend with its refusal on the direct websocket turn claim too ([1d7bc34](https://github.com/icoretech/codex-pooler/commit/1d7bc34459c40614245952bc426d52246e3d2156))
* **websocket:** answer a provider usage-limit frame on the last candidate with the terminal wrapped 429 and the Pool's advice ([adc04a9](https://github.com/icoretech/codex-pooler/commit/adc04a984640679f094d04f11bf6b0fb8aaff9da))
* **websocket:** answer invalid_model in the replay preflight for a disallowed model the Pool lists but does not serve, as HTTP does ([6e9ca76](https://github.com/icoretech/codex-pooler/commit/6e9ca76711cdcc7b8a9024e184b3685706febd22))
* **websocket:** answer the provider's codeless invalid previous_response_id refusal with previous_response_not_found and admit the client's full resend ([5c50894](https://github.com/icoretech/codex-pooler/commit/5c5089481a0f3613a4fcd687dddcb25f79fa008b))
* **websocket:** answer the resend of a turn whose provider refusal was final with that refusal instead of duplicate_turn ([d6993f5](https://github.com/icoretech/codex-pooler/commit/d6993f53b38d2c30d2091f200b32e802c42065d8))
* **websocket:** apply a closing socket's own detach that reaches the owner after the socket's exit, instead of refusing it stale_downstream ([d3a901f](https://github.com/icoretech/codex-pooler/commit/d3a901faa0f0cc96b670b19c580425a6342daee4))
* **websocket:** arm a closing socket's pre-visible replay without a database read and fail a stalled arm instead of stopping the owner ([72d071e](https://github.com/icoretech/codex-pooler/commit/72d071e0c22350e5d467b2d01e5c1afc441dd5e6))
* **websocket:** bind a queued resend's owner replay intent when the preflight names its predecessor ([ea88372](https://github.com/icoretech/codex-pooler/commit/ea8837247568b43f5d7f1feb04a2e2f135c1ada0))
* **websocket:** clear a native compaction admission armed for a socket another socket replaced at the owner ([c367a8b](https://github.com/icoretech/codex-pooler/commit/c367a8b5af9f55eb62a95108e31894c4a4f3c74a))
* **websocket:** complete an unknown-code provider 4xx refusal health-neutrally like its HTTP answer ([0a31e44](https://github.com/icoretech/codex-pooler/commit/0a31e440659f66aa3de06896e2af632b9249cb40))
* **websocket:** defer the owner-forwarded turn interrupt of a closing socket that already pushed its task's terminal ([8f43cab](https://github.com/icoretech/codex-pooler/commit/8f43cabd5d9a8c87a10efb441ea40b4f3f678c66))
* **websocket:** drop the admission-answer branches dialyzer proves unreachable for atom refusal reasons ([1877461](https://github.com/icoretech/codex-pooler/commit/1877461866622670eed2d00740e9a0015603b9b5))
* **websocket:** fence a closing downstream the owner accepted nothing of so its resend is served on the first retry ([a2a7aeb](https://github.com/icoretech/codex-pooler/commit/a2a7aeb285cc0f84b5b672376cfe78fdb71c4e2e))
* **websocket:** fold an owner admission refusal outside both vocabularies into invalid_transition at the owner's node ([745cf73](https://github.com/icoretech/codex-pooler/commit/745cf73cd8468184145715004d2d7f712d5460d9))
* **websocket:** forget a finished response task's model without adding the key to socket state ([31e6538](https://github.com/icoretech/codex-pooler/commit/31e65388870790156ce6d08afcb47766f718677a))
* **websocket:** give a native turn queued behind the previous turn's task the owner replay binding when it is dequeued ([b001ce4](https://github.com/icoretech/codex-pooler/commit/b001ce42a551294fc05d9e1e0bd25cfe43e1155d))
* **websocket:** give a remote owner detach the owner's call budget so a slow replay arm is not read as a lost owner ([3d18cb1](https://github.com/icoretech/codex-pooler/commit/3d18cb10511658dca3fd28c1dae7a5621a14f3b2))
* **websocket:** give the remote owner role probe the owner call budget and probe only the owner node ([db0eb27](https://github.com/icoretech/codex-pooler/commit/db0eb27bcf017482e1fc8955b04daf6deb33e6d9))
* **websocket:** give the remote V4 replay reconciliation the owner call budget ([4e4dc16](https://github.com/icoretech/codex-pooler/commit/4e4dc1618947fe6586c6e661832c9a82bdbca94c))
* **websocket:** give up the request claim of a row closed before anything reached the provider, instead of fencing every resend ([92a0097](https://github.com/icoretech/codex-pooler/commit/92a0097b7ec6b3004bd99c57a0c3a690a2f6ca67))
* **websocket:** keep a turn pre-visible until output or a terminal reaches the client, not on response.created ([601ebc9](https://github.com/icoretech/codex-pooler/commit/601ebc9a188c655041fd857944a73a24a640cb83))
* **websocket:** keep a turn whose terminal already reached the downstream when its socket detaches so its own result settles it ([70093f8](https://github.com/icoretech/codex-pooler/commit/70093f8035f5aea9be071baa9038fc4478d1d218))
* **websocket:** key a native compaction the socket queued behind the settling turn from its admission binding, so the owner never runs it as an unknown turn ([4530ea2](https://github.com/icoretech/codex-pooler/commit/4530ea20d5405cfafdf1908796d221cc8d858f78))
* **websocket:** lead a turn frame's newer window to the socket's session so a cut turn's reconnect redeems its replay ([fdb0719](https://github.com/icoretech/codex-pooler/commit/fdb0719a8cb6725a5203152788ef019719f7689f))
* **websocket:** let a different turn from the session's next socket retire an armed pre-visible replay ([5e756c3](https://github.com/icoretech/codex-pooler/commit/5e756c3d666f65010762b3b469a0c6510aa4cd7f))
* **websocket:** let a direct task whose terminal the socket already pushed settle its own turn when the socket closes ([2136ec2](https://github.com/icoretech/codex-pooler/commit/2136ec2ef8086e4ec489d5053db053bc172a9fd9))
* **websocket:** let a full-history turn carrying the provider's compaction checkpoint leave an exhausted account like its HTTPS fallback ([91befe5](https://github.com/icoretech/codex-pooler/commit/91befe5cadb8aadd0d8868ef67c8a273d193ad7a))
* **websocket:** let a request frame wait for the upstream websocket session instead of a fixed one-second call bound ([0d1d687](https://github.com/icoretech/codex-pooler/commit/0d1d68742089e890ed11da898ce9dbfdefc95866))
* **websocket:** let cancel_remote_downstream accept the per-call downstream the abandon fallback passes ([f7f44db](https://github.com/icoretech/codex-pooler/commit/f7f44dbadcf4c7266a58ebcb53723dcec36aeb63))
* **websocket:** let the released client's first retry of a compaction whose socket already closed take the running compaction over, and let a same-claim resend with owner forwarding off wait for its running predecessor ([d4b1f20](https://github.com/icoretech/codex-pooler/commit/d4b1f20c6646e4d6ba1c7550db93c29fe5c4cad4))
* **websocket:** let the released client's retry take over a collected full-history compaction whose socket already closed, instead of meeting the owner busy until that socket's detach ([acb2d68](https://github.com/icoretech/codex-pooler/commit/acb2d68dce79c647934e722cbf5623da9c7d65b0))
* **websocket:** let the replacement socket that already attached reattach to a lost owner generation ([3ab3333](https://github.com/icoretech/codex-pooler/commit/3ab33336e0116a76f882cf1ac46809989271859b))
* **websocket:** log a witness-less owner-detach interrupt of a socket cut before its turn started as routine ([844e7b8](https://github.com/icoretech/codex-pooler/commit/844e7b8f98b6881d118118bc218c3f63884746c1))
* **websocket:** log every refused native compaction reservation with the owner's cause, whichever route decided it ([d8db3eb](https://github.com/icoretech/codex-pooler/commit/d8db3eb2d4326e731ac110d3c68fe7f56ebef439))
* **websocket:** log the native compaction deferral stage when the dequeue refuses a deferred turn whose owner could not be asked ([91dd5e7](https://github.com/icoretech/codex-pooler/commit/91dd5e7dad59ecbcaa07d714fa4c69994f5a0c62))
* **websocket:** name quota_rejection and advanced_http_resume on the client resend admission line ([47ade1e](https://github.com/icoretech/codex-pooler/commit/47ade1ee429d2ec8e5ee612ef8a31a7ade59f0b3))
* **websocket:** never arm a native compaction for replay, so its cut settles and its resend is chained ([f1a26d0](https://github.com/icoretech/codex-pooler/commit/f1a26d089acdaf8ab706d844d3389d4be0a55979))
* **websocket:** ping the upstream websocket while a submitted turn waits for the provider ([f7b8102](https://github.com/icoretech/codex-pooler/commit/f7b81020737f3d23a04bb1266bbf0c332b267ac0))
* **websocket:** recognise the released client's full-history resend of an anchored turn as the same request ([cd57d36](https://github.com/icoretech/codex-pooler/commit/cd57d36b45d0584d9f69ed2413b87a5a00062fb4))
* **websocket:** record a delivered receipt for a public websocket turn whose completed terminal reached the client before it closed ([f38ef8c](https://github.com/icoretech/codex-pooler/commit/f38ef8cd2b99026d6fa9a3a89a6d18883d40f807))
* **websocket:** record a delivered receipt for a turn whose completed terminal a terminating socket already pushed ([d25f8a5](https://github.com/icoretech/codex-pooler/commit/d25f8a513c5144d5fce564c81345e350f66508a7))
* **websocket:** record a delivery receipt from what was written before the connection's first failed write ([023e760](https://github.com/icoretech/codex-pooler/commit/023e760f67807aeed7926ed982ed1949f506f315))
* **websocket:** record a refusal made before a request's claim under the socket's request id, never under the claim it would fence ([7e08ad4](https://github.com/icoretech/codex-pooler/commit/7e08ad43ff49e12f03270652642806a50269873a))
* **websocket:** record a timed-out remote response.processed forward as failed with an unknown upstream delivery ([55da5a0](https://github.com/icoretech/codex-pooler/commit/55da5a080bd404a9463e24c75fd4fb18814fe0ee))
* **websocket:** record an admitted native compaction under the claim its full-history resend derives ([86e7403](https://github.com/icoretech/codex-pooler/commit/86e7403227fb3fb0ed9d5cffcbd4c504631b7394))
* **websocket:** record and log a model the key or the Pool refuses in the owner's replay preflight, after its rollback ([bdaeece](https://github.com/icoretech/codex-pooler/commit/bdaeece6b6c7b1b6be98ccca745925dd186fd7ca))
* **websocket:** record provider rejection fields for a multi-line error frame and never a Pooler-derived code ([1561aaa](https://github.com/icoretech/codex-pooler/commit/1561aaad08d1e5d1e3b10e239212a29839ac640e))
* **websocket:** record the 429 a websocket usage-limit refusal answered, with its advised reset, and log it ([3451871](https://github.com/icoretech/codex-pooler/commit/3451871cf962b8885c94b924f3ef9abd78ae3d02))
* **websocket:** record the receipt of a socket-authored error frame after Bandit wrote it ([5d19843](https://github.com/icoretech/codex-pooler/commit/5d198437d16e10df6688dd596475812bce4266db))
* **websocket:** record the requested, effective and enforced model on a replay-preflight model refusal as the fresh path does ([09e72c8](https://github.com/icoretech/codex-pooler/commit/09e72c8af51a7bf30d35ce9c32ee1b084c1bae81))
* **websocket:** refuse a native anchored turn whose connection last served the other Full/Lite mode ([eca88af](https://github.com/icoretech/codex-pooler/commit/eca88af610d06e73c3044c0b9b53bfbe0fb2b4d3))
* **websocket:** refuse a non-finite remote turn budget override at the dispatch boundary ([33033fd](https://github.com/icoretech/codex-pooler/commit/33033fd9eda91b5aa75c580d315d575d960cc565))
* **websocket:** refuse a remote turn submission that reaches the owner after its abandon ([e7adcae](https://github.com/icoretech/codex-pooler/commit/e7adcaef5c49460f5c1ab966166c9dab2f479283))
* **websocket:** refuse a timed-out turn submission whose abandon found no owner registered on the owner node ([8372a90](https://github.com/icoretech/codex-pooler/commit/8372a90b57f359da49dc2ee06f88239662469043))
* **websocket:** refuse an incremental compaction the owner granted no admission before dispatch instead of billing it and wedging its turn ([6e4481b](https://github.com/icoretech/codex-pooler/commit/6e4481b07f06cd4d27dd01b4f5c17bf37e85e2ca))
* **websocket:** refuse only a Lite anchored turn on a connection whose last response was served in Full ([7697a51](https://github.com/icoretech/codex-pooler/commit/7697a51aa3adb89871c83eb4cd8ea02e855b0f6b))
* **websocket:** relay a withheld-advice usage limit classified on the websocket and redacted with its circuit wait on /v1 ([c476c0c](https://github.com/icoretech/codex-pooler/commit/c476c0c33029a9a112f8bb2945cbfbfc7f8c9b16))
* **websocket:** release a turn claim whose reservation rolled back instead of leaving it to fence every resend ([bdeffd4](https://github.com/icoretech/codex-pooler/commit/bdeffd40a61d58474bc1b566c52c4bf4ddcbccff))
* **websocket:** reopen a public /v1 turn's owner leg for the task's failover attempt so its frames and commit probe are answered at once ([a09dbf4](https://github.com/icoretech/codex-pooler/commit/a09dbf43038c0dcdb20363052141b2c399c2aeff))
* **websocket:** run a deferred final compaction turn whose owner holds no admission as the ordinary turn instead of refusing it 503 ([1aed625](https://github.com/icoretech/codex-pooler/commit/1aed6259d625bb2d9bf94d8a97978b9030e2cb30))
* **websocket:** send a codeless or unrelayable provider 400 to the native websocket client as the wrapped error instead of a retryable response.failed ([38cf7cd](https://github.com/icoretech/codex-pooler/commit/38cf7cd2be6df772f683f49c876f32a8be59de95))
* **websocket:** send a demoting provider 403 as the final wrapped 400 when the Pool has no other routable assignment ([d6e64e3](https://github.com/icoretech/codex-pooler/commit/d6e64e3df855ee96f9b87ff0f8d48987639f76f2))
* **websocket:** send a final provider 4xx refusal to the native websocket client as the wrapped 400 instead of a retryable response.failed ([90933ad](https://github.com/icoretech/codex-pooler/commit/90933ad2279d7d1e81a548db9e8bac8dd7be3ad4))
* **websocket:** send a provider validation refusal to the native websocket client as the wrapped error the HTTP answer relays ([870272e](https://github.com/icoretech/codex-pooler/commit/870272e0b2c076398b37192b5b699aaa8dad4148))
* **websocket:** send the Pooler-written message naming the status for a kept provider 401 or demoting 403 refusal ([5e72ccb](https://github.com/icoretech/codex-pooler/commit/5e72ccb2b5c15410d9b7a9aaf6514cf6c1b7e33b))
* **websocket:** serve a steered frame anchored on the response its own turn just completed on the socket ([a646e38](https://github.com/icoretech/codex-pooler/commit/a646e382e5e222dbb5a17f1fee1ae5f24b2796d1))
* **websocket:** serve the grown resend of a turn cut after completed items as one successor when it appends exactly the items the socket pushed ([53d718f](https://github.com/icoretech/codex-pooler/commit/53d718f909f83ea74660ef859a752197d49f5d29))
* **websocket:** serve the identical resend of a turn cut after only lifecycle, item-opening and delta frames as one successor ([4730682](https://github.com/icoretech/codex-pooler/commit/4730682a874e8cc88d9210bf2f7fc9817ef0aa95))
* **websocket:** start the client-retry window of a turn cut by a failed downstream write at that failure ([0f9bae8](https://github.com/icoretech/codex-pooler/commit/0f9bae8986f09ec0f94bf17d959ce072a259f9f8))
* **websocket:** stop a direct response task its client left before any output before interrupting its request ([5dc0ab9](https://github.com/icoretech/codex-pooler/commit/5dc0ab9d84b9aa53569c8dc32b854a0c409f7b29))
* **websocket:** stop a pre-visible direct task only while it waits on its upstream request ([e525f36](https://github.com/icoretech/codex-pooler/commit/e525f36ae858b7b648e52078d684628c5fe18283))
* **websocket:** stop a timed-out client-retry turn at a remote owner instead of letting it stream to a client that got its error ([bb08e6c](https://github.com/icoretech/codex-pooler/commit/bb08e6c45765b0b159c8400b6fda38b04b8c664c))
* **websocket:** stop a timed-out turn on an owner node without the abandon through its per-call cancel instead of the detach that armed a replay ([7b8a2be](https://github.com/icoretech/codex-pooler/commit/7b8a2be96553ffff473c5cc3d1e9b9dca8f6503f))
* **websocket:** stop detaching the downstream after a remote response.processed forward times out ([48c93e9](https://github.com/icoretech/codex-pooler/commit/48c93e954c44393a8a49c6638ab809874329c1ab))
* **websocket:** stop only the timed-out turn at a remote owner instead of detaching the connected socket ([e275fd7](https://github.com/icoretech/codex-pooler/commit/e275fd716d3a443e3e2cfc43f6807617988e950a))
* **websocket:** stop the predecessor's task before invalidating the upstream connection at the handoff soft timeout ([5924c6b](https://github.com/icoretech/codex-pooler/commit/5924c6b111fb8d789fe6da2f37420bebfe9e77a8))
* **websocket:** take in the terminating socket's post-cleanup drain only the results of the tasks it awaits ([046b147](https://github.com/icoretech/codex-pooler/commit/046b14700fcb6a1a5b22d920daea8c75f57a2dca))
* **websocket:** take over the running turn a reconnecting socket inherited when it sends its own request ([d0e5c9c](https://github.com/icoretech/codex-pooler/commit/d0e5c9c046942c72c7ed2512e7d6a7879d58357e))
* **websocket:** wait for, or refuse, a same-turn claim while that turn's previous request still runs, instead of a 500 ([b548cf5](https://github.com/icoretech/codex-pooler/commit/b548cf5c1081e64273bb5c51d1d5a0cb36afd108))


### Performance Improvements

* **admin:** count request logs at most 10,000 rows past the current page ([ac47139](https://github.com/icoretech/codex-pooler/commit/ac4713956bcd04b51d5fb92a46599dee317ac47b))
* **admin:** list the request-log model filter from an index instead of scanning every request ([d1b94f8](https://github.com/icoretech/codex-pooler/commit/d1b94f8e6ad7a6aa2e46e8bfed041796b78a3523))
* **admin:** probe each window request for the identity's attempt in the cockpit Pool contribution instead of joining its grouped history ([924b197](https://github.com/icoretech/codex-pooler/commit/924b197374b3c273e0e0d3b3c7b4f4b3cfe17820))
* **admin:** walk an upstream account's recent cockpit events from its own attempts ([27ff8af](https://github.com/icoretech/codex-pooler/commit/27ff8afa768cd10c3199decf82e18e5640dbfbdf))
* **db:** index the foreign keys a Pool, assignment, key, identity or session delete looks up ([248d2f3](https://github.com/icoretech/codex-pooler/commit/248d2f3edf501a294a5c46883807dc35818b4241))
* **gateway:** probe each window turn's request by primary key in the dashboard turn statuses instead of joining the Pools' requests ([9d70dd4](https://github.com/icoretech/codex-pooler/commit/9d70dd42eee3662b4cbb678bc2ebb0a75890e092))
* **gateway:** resolve a native HTTP turn claim once per request and hash its input once for both witness variants ([0aeb6d7](https://github.com/icoretech/codex-pooler/commit/0aeb6d7c669d91576bb7a03db10c477e0925e805))


### Reverts

* **upstreams:** remove the operator clear for a provider-requested usage polling pause ([899bf5a](https://github.com/icoretech/codex-pooler/commit/899bf5aa3695a2318e6263aa35eb593e48feb465))


### Tests

* **access:** sample a lock wait again when its pg_stat_activity query names no relation ([9e97fc4](https://github.com/icoretech/codex-pooler/commit/9e97fc48ebcf509717c9c83b59c3bedfc6996369))
* **accounting:** give the request-log model plan test a production-shaped history and assert its statistics ([c86417a](https://github.com/icoretech/codex-pooler/commit/c86417aa8336d002a9453ca9035aa02d8c3b9889))
* **accounting:** hold the enforcement-clock test's pending reservation on a live request ([afab76a](https://github.com/icoretech/codex-pooler/commit/afab76a17dc45b535df32802d8bde74e76893363))
* **accounting:** honour pricing_ref in model_fixture and price the explicit-ref case only through the ref ([e540ae7](https://github.com/icoretech/codex-pooler/commit/e540ae7ebac3a8fa3a6ad9e2312638055a8c7ce1))
* **accounting:** pin that the minute replay job and the superseding retirement each settle an interrupted turn once ([ddc4d40](https://github.com/icoretech/codex-pooler/commit/ddc4d4045bcb4bceef2d72b392c9ee4188d83fc8))
* **accounting:** plan the Observatory contract on empty relations so earlier tests' bloat cannot mask or flip it ([745a89d](https://github.com/icoretech/codex-pooler/commit/745a89d46798cdb29b97fa3d3914eb054ac736c9))
* **accounting:** sample a lock-order wait again when its pg_stat_activity query names no relation ([d70fff1](https://github.com/icoretech/codex-pooler/commit/d70fff1ef458f2f1e7fcb85acce12cfe3b614ead))
* **accounting:** seed the retained active-count history in batch and split the replay mutation races ([9f55343](https://github.com/icoretech/codex-pooler/commit/9f55343bde4f4eecf168cc12aa2fa5cd44fd88e1))
* **admin:** analyze the bulk cockpit fixtures and assert populated statistics before measuring the recent-event walk ([299e5c4](https://github.com/icoretech/codex-pooler/commit/299e5c4726d61ab2f9ca290bec7714ecc16e2c16))
* **admin:** keep the Spark convergence cards inside the quota freshness TTL until the page renders ([b40d995](https://github.com/icoretech/codex-pooler/commit/b40d995e45f182e3559b64e2505e0ff8f2e9ab74))
* **admin:** start dense cockpit fixture attempts at their admission and budget every recent-event probe ([96f9345](https://github.com/icoretech/codex-pooler/commit/96f9345805feb2f2bd83d2365eecb3d9330bc662))
* **alerts:** pin alert state and routing for a window whose only exhausted row describes an ended cycle ([40b117d](https://github.com/icoretech/codex-pooler/commit/40b117d53999547ae7ec4a4d1901301e37a87df5))
* await tasks under named detection budgets instead of fixed one-second waits ([26a4f09](https://github.com/icoretech/codex-pooler/commit/26a4f097195288199b88515d59ed9c45921ffe8a))
* block the reliability QA preparation fixture until released so only the cap can end it ([90e679a](https://github.com/icoretech/codex-pooler/commit/90e679a19515f27025f2f3d5a38eefbb9dcb589f))
* bound hosted shell output classification by reductions instead of wall-clock time ([8e91a39](https://github.com/icoretech/codex-pooler/commit/8e91a39deaa1710e311b18eaae79d51f68d6f6c8))
* **bridge:** pin continuity of the session's next turn after a bridged usage-limit failover ([1a80144](https://github.com/icoretech/codex-pooler/commit/1a801448609bc112c606992a9004d03b632d874c))
* **catalog:** make the default gateway fixture model a catalog entry the released Codex client decodes ([91ca543](https://github.com/icoretech/codex-pooler/commit/91ca54313a029b489bf521944f4c5d4773a68ed2))
* **compat:** alias WebsocketTurnIdentity in the contract test's claim scope helper ([5d20e27](https://github.com/icoretech/codex-pooler/commit/5d20e2797766c49800b1258eab89f462a27f74c7))
* **compat:** state the thread-or-session claim scope of the native websocket turn key in the matrix ([5e44572](https://github.com/icoretech/codex-pooler/commit/5e44572c1c5a9acce786e2af221ddfe3dc6c67e3))
* **config:** let a shared-sandbox checkout wait behind a long holder instead of dropping it after 100 ms ([465a6af](https://github.com/icoretech/codex-pooler/commit/465a6afe4ac95e646dd3ab96191c8ce58096fa93))
* **config:** point the test CodexAuth issuer at a closed loopback port ([3dad966](https://github.com/icoretech/codex-pooler/commit/3dad966ff166d2ab24d273c2cf9e49dc9a76a83d))
* **continuity:** expect the rejected request row for a pre-reservation owner refusal in the reservation test ([4f0e0fe](https://github.com/icoretech/codex-pooler/commit/4f0e0fe103ae248a454e1e9eb91d2c27c3672132))
* **deletion:** pin the scheduling and reactivation race, an interrupted job run, the jobs explorer and a turn on a key being deleted ([7d743bb](https://github.com/icoretech/codex-pooler/commit/7d743bb5f82f1a800de5111d32766a950d78defb))
* **dev:** cover the tool-compatibility certification preference for gpt-6-sol ([703b141](https://github.com/icoretech/codex-pooler/commit/703b1418e059ee820695372a2d879eacc23ae3a7))
* **dev:** cover the tool-compatibility certification's exact gpt-6 family discovery ([be35785](https://github.com/icoretech/codex-pooler/commit/be35785d7201b59c4795acda2c6f08dd2277b403))
* **dev:** record that each jobs-off fixture task writes the disabled Oban env before app.start ([1fe71a2](https://github.com/icoretech/codex-pooler/commit/1fe71a22710ddc1e631214c0a1a66f61cbe65be6))
* drop hardcoded Codex client versions from test names, comments and provenance lines ([ab6eb27](https://github.com/icoretech/codex-pooler/commit/ab6eb2732b7d391096487931d2fbcc3adbf31428))
* drop measured-on Codex versions from the owner-forwarding replay test comments ([6ed3206](https://github.com/icoretech/codex-pooler/commit/6ed3206655c3b2d058415732517ef45bb8ae1364))
* drop measured-on Codex versions from the websocket resend test comments ([90c7e6d](https://github.com/icoretech/codex-pooler/commit/90c7e6d6ba0258e992ff30902471bc5548594d1b))
* **fake-upstream:** refuse a model the account cannot serve before previous_response_id over HTTP, as the provider does ([950c039](https://github.com/icoretech/codex-pooler/commit/950c039903c4e1cf49b4a9333ea752d33e60febb))
* **fake-upstream:** refuse previous_response_id over HTTP the way the provider does ([9c49004](https://github.com/icoretech/codex-pooler/commit/9c4900428fd41d72e292d7646583fafa5630d974))
* freeze the drain wait-failure clock and give the metrics sampler a local name ([224ba95](https://github.com/icoretech/codex-pooler/commit/224ba9586fa01346be416297c0610c4954cfd38a))
* **gateway:** expect owner_unavailable for replay intents refused on a session binding or Pool mismatch ([fe03bc1](https://github.com/icoretech/codex-pooler/commit/fe03bc1136c96799651ad18782eedf7d3e8c3c1f))
* **gateway:** expect owner-forwarded public websocket turns to drop codex.* controls ([8cb42d3](https://github.com/icoretech/codex-pooler/commit/8cb42d34bd4dbe16df69d9bb6848358a4ed7017a))
* **gateway:** expect the public websocket to drop the owner-forwarded metadata event ([b9bb69c](https://github.com/icoretech/codex-pooler/commit/b9bb69ca427a70f6687ae156ac8692d045fb7aa8))
* **gateway:** keep the owner-lease renewal tests' pre-dispatch window off the short heartbeat ttl ([719924a](https://github.com/icoretech/codex-pooler/commit/719924aa93bbadffdfeeacb60d8c3b870b2dbc89))
* **gateway:** leave bitmap index entries out of the turn-status plan budget ([4e9d9f6](https://github.com/icoretech/codex-pooler/commit/4e9d9f6b0d628800cc1db3bed52824bab35bd1e6))
* **gateway:** pin post-turn compaction, client exit and resume on a new socket at both topologies ([7cf1eb6](https://github.com/icoretech/codex-pooler/commit/7cf1eb6a9f2c1b1a051a3d4d9bab1ed4b33b773a))
* **gateway:** wait for transport messages under named detection budgets ([ab41d5d](https://github.com/icoretech/codex-pooler/commit/ab41d5df79480d402e367521214ce83c699e36da))
* give short detection budgets and fixture releases the named 15 s and 60 s bounds ([638fbf2](https://github.com/icoretech/codex-pooler/commit/638fbf2005da826049bb9ca31060126a6dcc242f))
* hold the cross-assignment failover behind an upgrade barrier instead of a 100 ms connect timeout ([b127eea](https://github.com/icoretech/codex-pooler/commit/b127eeabded21eed5764d2da90fc8e4f983f1b6f))
* hold websocket test teardown until every deferred termination cleanup has finished ([e7e0959](https://github.com/icoretech/codex-pooler/commit/e7e0959fa78f21f3f819248e92a11c45b0030473))
* **jobs:** settle the simultaneous stale-recovery reconcilers one after the other in both orders ([badb6ca](https://github.com/icoretech/codex-pooler/commit/badb6ca1fb61b99004065ed784a6b5e20e7ac19a))
* keep ExUnit's failure exit status when the duration guard also fails the run ([f56667e](https://github.com/icoretech/codex-pooler/commit/f56667ec02dd36472063004d6458c805144737e6))
* **migrations:** flatten the lock-wait waiter session helper below the credo nesting limit ([a5b9b61](https://github.com/icoretech/codex-pooler/commit/a5b9b61d6e1abe61be0089e4e46bad4cc28c32e0))
* move bare gpt-5.6 family references to gpt-6 and certify the dev tool smoke on the gpt-6 family ([9647858](https://github.com/icoretech/codex-pooler/commit/9647858f893f24d6ab676fc37ec8f2f4c06b3a86))
* move the remaining short detection waits in four gateway and controller test files to named 15 s budgets ([1994885](https://github.com/icoretech/codex-pooler/commit/199488513fc38cc50ad660f9b711f1a2610300d8))
* move the websocket accounting, payload and owner-death detection waits to named 15 s budgets ([6bd52f5](https://github.com/icoretech/codex-pooler/commit/6bd52f576094edeaa6de57cd0fb8a68406b8cd4e))
* **openai:** pin a /v1 message and tool-output input_image file_id on Full and Lite models ([8b72a92](https://github.com/icoretech/codex-pooler/commit/8b72a9275f5e95e49544529124e1d06a569c8779))
* **persistence:** gate the COMMIT-deadline renewal on a lock the test holds and prove the trigger ran, instead of racing a 2 s sleep ([fb3fb36](https://github.com/icoretech/codex-pooler/commit/fb3fb36477cbf2d9a44e83ba856a8505996c221d))
* pin the unresponsive leaked-owner drain bound end to end in the drop-on-exit acceptance ([1292c59](https://github.com/icoretech/codex-pooler/commit/1292c5938f948b54d3e93faf67514fc6d3364122))
* **platform:** give every call into a BEAM peer a 15 s detection budget ([56adec2](https://github.com/icoretech/codex-pooler/commit/56adec2588e0fb763712e7a3f9492da2e167a2bc))
* **platform:** keep make test-fast's duration candidates file out of the guard's probe VMs ([8c4d011](https://github.com/icoretech/codex-pooler/commit/8c4d0110341b4f4a80deaed7425a7ca1329e59b8))
* **platform:** publish a BEAM peer's presence through the production heartbeat ([d6c9f90](https://github.com/icoretech/codex-pooler/commit/d6c9f9055e5eb08ac0a54b843f6b37fcf5434dd0))
* poll committed rows, owner state and LiveView loads on a monotonic 15 s deadline instead of a one-second or attempt-counted budget ([c699609](https://github.com/icoretech/codex-pooler/commit/c6996098165d3720ad17961a64be31b4c01e537f))
* **quota:** keep sampling the pruner's lock wait until pg_stat_activity names its wait event ([14c601a](https://github.com/icoretech/codex-pooler/commit/14c601a606a00737a87628364116b79a4410faf5))
* register the relay runtime, admission and activity registry test processes under local names ([0c0317a](https://github.com/icoretech/codex-pooler/commit/0c0317acf60d05e5c9583b7791a42e10460b98d7))
* replace retired gpt-5.4, gpt-5.5 and gpt-5.6 model ids in tests and dev fixtures ([e4ac10f](https://github.com/icoretech/codex-pooler/commit/e4ac10ffbced1b763b66f9477b3d3bee015f23a3))
* replace the retired gpt-5.4-mini default and test model with gpt-6-luna ([49c4879](https://github.com/icoretech/codex-pooler/commit/49c487995bd1123e0f382591d5d15c87473d7cdd))
* replace the retired model ids in the payload normalizer test ([347aeb5](https://github.com/icoretech/codex-pooler/commit/347aeb5e8a2e6f7171ebf82fa511a2a2ee5bb90d))
* report tests over the normal duration limit instead of failing the run ([d069caf](https://github.com/icoretech/codex-pooler/commit/d069cafb1bdd1964447c816f8e2b75c08c7bfcc4))
* **resets:** pin that a workspace marker on the target does not decide automatic redemption ([4a0e1bc](https://github.com/icoretech/codex-pooler/commit/4a0e1bc24e3b98c83482d3ddd15b7754d4383337))
* **routing:** bind the pinned-session failover arm's session to the refusing account deterministically ([b798099](https://github.com/icoretech/codex-pooler/commit/b798099172d44e8fc268014d255c381788d27b74))
* run the make test-fast acceptance under a test run namespace instead of skipping every case ([12335f4](https://github.com/icoretech/codex-pooler/commit/12335f42e866497ba66bee00c810e052bc205293))
* **runtime:** wait for backend websocket and reset probe messages under named detection budgets ([b89604c](https://github.com/icoretech/codex-pooler/commit/b89604cc45a3d5a8afbc5995bf243df17c793669))
* **saved-resets:** give barrier waits the detection budget and outlast it at every task handoff ([236a97c](https://github.com/icoretech/codex-pooler/commit/236a97cebf91ad364855beba4ff12ecd201ebcb2))
* **saved-resets:** give the 200-member cohort lock test's siblings only the rows its claim reads ([b5fab8a](https://github.com/icoretech/codex-pooler/commit/b5fab8a0dc630bb3e32e1a56dbd58e655aa7a019))
* **support:** restore daily_rollup_coverages rows a sync test's commits make across 00:00 UTC ([9022bc6](https://github.com/icoretech/codex-pooler/commit/9022bc6be623b7fc5bbea5f627faafcb1fa4b0d1))
* **support:** start every sync case-template test at the configured Logger level after the queued handler removals ([d3b035e](https://github.com/icoretech/codex-pooler/commit/d3b035e4726a0897ee6835ff65615967a9a0153d))
* **support:** wait for every running websocket session cleanup before the sandbox owner stops or committed rows are deleted ([07af6eb](https://github.com/icoretech/codex-pooler/commit/07af6eb0a3149bef53e06c43261fa7a74c211453))
* **telemetry:** compare only the prometheus reporter test's own series across concurrent scrapes ([34e209e](https://github.com/icoretech/codex-pooler/commit/34e209ec251f4fbceb7985569bd3439e4ebdf0b2))
* **usage:** anchor the monthly-only /v1/usage test at the current time so the 30-day retention keeps its window ([6573612](https://github.com/icoretech/codex-pooler/commit/657361238692f98e1cffa1049a1bfd1b540168ad))
* **usage:** pin the usage routes answering no_upstream_usage once an account's only evidence is past retention ([71751ab](https://github.com/icoretech/codex-pooler/commit/71751abdc1a26335a1d42f67bf580b27444468d2))
* use gpt-6-sol as the cleartext model fallback in the quota parser identity test ([34617df](https://github.com/icoretech/codex-pooler/commit/34617df11d8ac3a9f7a433ef5ef26255aca7b961))
* **v1:** expect rate_limit_error on the redacted upstream 429 that cannot impersonate a cap denial ([9289c89](https://github.com/icoretech/codex-pooler/commit/9289c89d2751a27a6c6671abd2703780f6d4c25d))
* **v1:** expire the silent bridge's preflight once the provider holds the request and give the provider barriers a detection budget ([fe7c0db](https://github.com/icoretech/codex-pooler/commit/fe7c0dbd0861af61d93fdddd8e80dfde3d3d8b7f))
* **v1:** wait for file upload and websocket bridge messages under named detection budgets ([5e14217](https://github.com/icoretech/codex-pooler/commit/5e142179832139189a656a1e693681ec9ae0e35a))
* wait for domain, fake upstream and relay messages under named detection budgets ([197f14d](https://github.com/icoretech/codex-pooler/commit/197f14dbac9ce24683c853b7d5f6416da258dcf5))
* wait on the 15 s detection budget in the rate-limit, sandbox-allowance, trace and accounting-boundary receives ([631dbe7](https://github.com/icoretech/codex-pooler/commit/631dbe79c56763f413bce63bf89ba510b5c789d5))
* **websocket:** await the socket's deferred cleanup before reading a rollout-shutdown drain ([b0812b3](https://github.com/icoretech/codex-pooler/commit/b0812b315d1e00c601d38a42bc974eaea7be2b39))
* **websocket:** await the socket's deferred cleanup before reading an aborted delivery receipt ([427846f](https://github.com/icoretech/codex-pooler/commit/427846fc9ffb16917a9b070b34b727c8294f2f4f))
* **websocket:** capture the withheld-advice refusal line until the refused turn's row settles ([5ea4f86](https://github.com/icoretech/codex-pooler/commit/5ea4f8679b3759692da8954482ff3612c7c9dd43))
* **websocket:** correct the retry claim in the missing-provenance compaction refusal pin ([c4fa1d6](https://github.com/icoretech/codex-pooler/commit/c4fa1d6e12bbb10c89bc20f9db3ff96ea2bcb12d))
* **websocket:** count the full-history compaction cut rows only once every row settled ([7f91717](https://github.com/icoretech/codex-pooler/commit/7f917171eaa4ebc2e64e1b78fe7fd4d66c28e2f0))
* **websocket:** deliver the keepalive and pong-deadline timer messages in the pong-liveness tests ([09ed12b](https://github.com/icoretech/codex-pooler/commit/09ed12bf3a4ec0c3224bf9c5ee7e09aea09fa8f1))
* **websocket:** drive the findings[#168](https://github.com/icoretech/codex-pooler/issues/168) provenance fixture through an authenticated key and a routable model ([abb1aea](https://github.com/icoretech/codex-pooler/commit/abb1aead8f0837970f51543b5653200a717a708c))
* **websocket:** drop an unverified persistent_term claim from the remote turn timeout test ([9c9745b](https://github.com/icoretech/codex-pooler/commit/9c9745bcab0fbe6262451d67f3df16dc69674b06))
* **websocket:** expect the retryable service_unavailable when the compaction reservation loses its database connection ([6145c44](https://github.com/icoretech/codex-pooler/commit/6145c44609f6c2da028e4f2ef42ede1c67023d01))
* **websocket:** expire the upstream upgrade deadline on a clock the test answers, not an 80 ms timer ([993e877](https://github.com/icoretech/codex-pooler/commit/993e87742c2bbfaa84397a106137c5c12f90b2ab))
* **websocket:** fail the owner's replay arm on a real pool checkout drop instead of the sandbox queue ([81727cc](https://github.com/icoretech/codex-pooler/commit/81727cc0e922b27f68d8983ac104e107c365d3c6))
* **websocket:** give the rollout drain tests their own owner registry ([0009331](https://github.com/icoretech/codex-pooler/commit/000933172010bbf9c7fff86e2db15f08039dfa32))
* **websocket:** hold the connection-limit turns on the held session timeouts and keep the owner harness barriers beyond the detection budget ([fd78edc](https://github.com/icoretech/codex-pooler/commit/fd78edcd4be7ddf169586f427b8e3f5aa6595c5d))
* **websocket:** hold the upgrade, pong-deadline and caller-death scenarios on held timeouts ([5da66a6](https://github.com/icoretech/codex-pooler/commit/5da66a64df8ce58f0977384cf73a0ab0defe8d8a))
* **websocket:** hold the upstream websocket session tests' in-flight turns beyond the scenario timeouts and move their waits to 15 s budgets ([aa0b50c](https://github.com/icoretech/codex-pooler/commit/aa0b50c9e70b27f4fd3eb061616b882f21cb3692))
* **websocket:** inject the owner's terminal-delivery timeout in the result-first tests and move their waits to 15 s budgets ([cd2a317](https://github.com/icoretech/codex-pooler/commit/cd2a31701b963da2549d805fa9c0e617708966f5))
* **websocket:** keep log capture open from fence install until teardown so cleanup_deferred never reaches the console ([42b5268](https://github.com/icoretech/codex-pooler/commit/42b5268dd2f163fcd2c7b55eedc9e5a83e279df4))
* **websocket:** let the public websocket receive helpers take only their own connection's socket messages ([04fb3c7](https://github.com/icoretech/codex-pooler/commit/04fb3c7b6d5a9c8bc1e931fda92ff519a00f4e58))
* **websocket:** let the real-owner rollout drain test drain owners in its own registry ([d95db1e](https://github.com/icoretech/codex-pooler/commit/d95db1e433dc3bf39efcf0ef5687b1368c4be25a))
* **websocket:** name the ledger row of the refused-retry diagnostics in the pre-turn compaction cut scenario ([d884d90](https://github.com/icoretech/codex-pooler/commit/d884d90b6b73c7553f603356583a88c3720dddbc))
* **websocket:** pin a native continuation refused before its claim under the socket's request id, taking neither the request nor the turn claim ([d6b5ac1](https://github.com/icoretech/codex-pooler/commit/d6b5ac11b5e804bde3fd15e4f7c5463e556d77c1))
* **websocket:** pin a post-visible close, an owner death under the abandon and a submission between the abandon's lookups on remote turns ([95867c9](https://github.com/icoretech/codex-pooler/commit/95867c95246dd3499a8939aae58d39e023311d94))
* **websocket:** pin that a closed socket's late early-detach call cannot fence the downstream that replaced it ([9dacb56](https://github.com/icoretech/codex-pooler/commit/9dacb56a442c4e64858e99055f50f3394a11dea5))
* **websocket:** pin that a completed-item cut's original generation is stopped beside its served grown resend ([0378017](https://github.com/icoretech/codex-pooler/commit/03780174d756486893c255942d136b3a428a218d))
* **websocket:** pin that a Full-served turn forwards a client-built Lite-shaped request as sent ([69ae0c7](https://github.com/icoretech/codex-pooler/commit/69ae0c7d7acf1ce63d39f7e014a4e8de75cb7324))
* **websocket:** pin that a late resend of an interrupted turn is served once with owner forwarding off ([ed7bdeb](https://github.com/icoretech/codex-pooler/commit/ed7bdeb38de29794327ba26495b0e6a6dea3b603))
* **websocket:** pin that a queued later turn meets every replay-preflight refusal again in the ordinary checks ([4966ae7](https://github.com/icoretech/codex-pooler/commit/4966ae789e4d38a01d5399c0169da7e2d7e86683))
* **websocket:** pin that a remote-owner turn's attempt names the proxy executor recovery asks about ([4a6c8c4](https://github.com/icoretech/codex-pooler/commit/4a6c8c4166395d227422bb3fa3c81ee4fdb4508f))
* **websocket:** pin that a reserved websocket request always carries its turn, so the direct interrupt never meets a reservation it cannot release ([28aa2ee](https://github.com/icoretech/codex-pooler/commit/28aa2ee3e195e43c17fb3bed88123c14a9f7a0ae))
* **websocket:** pin that parent and subagent sockets of one root session keep their own compaction admissions ([7a83135](https://github.com/icoretech/codex-pooler/commit/7a83135bbcabddf46941ce917826dd497a08c5c5))
* **websocket:** pin the 429 row of a withheld-advice usage limit on every websocket and bridged surface ([d6587ed](https://github.com/icoretech/codex-pooler/commit/d6587ed69ad9ad0b3499462371e9733cac360bda))
* **websocket:** pin the all-exhausted terminal 429 and its retry-after on the public /v1/responses websocket ([9bd1e45](https://github.com/icoretech/codex-pooler/commit/9bd1e45df4ec9a01bf3512110a15a82de2c2d477))
* **websocket:** pin the corrected single settlement of a direct turn whose provider answers after its client left post-visible ([aa69bef](https://github.com/icoretech/codex-pooler/commit/aa69bef606a1f02cc25979d37cdf8ae3074e80e1))
* **websocket:** pin the frame window alias guard with two live processes on one thread and a held alias row ([b916c2f](https://github.com/icoretech/codex-pooler/commit/b916c2f52ffa68d9b307fd4cbf8d973ffa5afe5a))
* **websocket:** pin the HTTPS fallback after a two-request websocket resend chain ([1c6403a](https://github.com/icoretech/codex-pooler/commit/1c6403a62e49019a94120b812fe08bdb3b36e113))
* **websocket:** pin the key of a native compaction queued behind the settling turn, and that no resend of it is a second provider generation while it runs ([e44b462](https://github.com/icoretech/codex-pooler/commit/e44b462d26bed6841c422d6968c0bf7985908a09))
* **websocket:** pin the missing-provenance compaction refusal on a replacement socket and why its item cannot carry the turn ([9922623](https://github.com/icoretech/codex-pooler/commit/99226235910ac9d407afc6418eb49a46b6fefcf3))
* **websocket:** pin the provider's model refusal of an anchored turn on its producing connection as a final refusal, not the anchor-miss retry event ([5c1d144](https://github.com/icoretech/codex-pooler/commit/5c1d14459eddbb73ada5b1fbdee96f59ded42abd))
* **websocket:** pin the replay cleanup sweep settling a consumed replay whose dispatch lookups failed ([5590311](https://github.com/icoretech/codex-pooler/commit/55903113144b39cce6d795da6ee355f38da0804f))
* **websocket:** pin the reply, row and refusal line of a turn whose key enforces a model the Pool does not serve ([52ad892](https://github.com/icoretech/codex-pooler/commit/52ad892f013a9a133177ff20b7213ce3cd0bb184))
* **websocket:** pin the row, log line and model metadata of a compaction frame refused for a model the key may not use ([9cd80bb](https://github.com/icoretech/codex-pooler/commit/9cd80bb4db7059c4f0b0e3b7d83c508838b9f2e4))
* **websocket:** pin the stale_owner refusal of the next turn after an old owner node's per-call cancel and the reconnected socket's service ([42db784](https://github.com/icoretech/codex-pooler/commit/42db7847df0e75fe589c4e02f376c7d1d155ea5f))
* **websocket:** pin the take-over wait bound of a cut compaction's first retry and accept only that bound in the cleanup-held arms ([c7d67ec](https://github.com/icoretech/codex-pooler/commit/c7d67ec6781c3ed176a3faefe98ecb7de67ac0f6))
* **websocket:** re-run the usage-limit answers and the held-back partition hop over a remote owner on a peer node ([9f6bcbd](https://github.com/icoretech/codex-pooler/commit/9f6bcbdea910a347e72c85a8b40fe6742b8a4367))
* **websocket:** read the turn-authority rows after the socket's session cleanup signals it finished, not when terminate returns ([5cf5f60](https://github.com/icoretech/codex-pooler/commit/5cf5f60363afbc8b4c7fac162442493379d8094e))
* **websocket:** read what the session cleanup writes only after it finished, not after terminate/2 returns ([1b10adb](https://github.com/icoretech/codex-pooler/commit/1b10adba38c59504ca73b1409fd89596f76dc4ad))
* **websocket:** release a collected compaction that ends in a provider error, and refuse a remote item mismatch with 409 ([4ceee1d](https://github.com/icoretech/codex-pooler/commit/4ceee1d054089356bd6ee593006dc3163a1d763c))
* **websocket:** release the cleanup fence only after its log holder has closed both captures ([cbe4828](https://github.com/icoretech/codex-pooler/commit/cbe4828f9e058fd03de6176e5cc560436eb1ff6b))
* **websocket:** release the held provider of a cut post-visible turn only once the original settled, not on its delivery receipt ([906698a](https://github.com/icoretech/codex-pooler/commit/906698a366c136f20039f95dd1c2fa2c400bde9c))
* **websocket:** release the owner recovery only once the closing socket's early owner call is queued at the starting replacement owner ([09f7c30](https://github.com/icoretech/codex-pooler/commit/09f7c306742f2a8690c601ab01bffe89850b4f5b))
* **websocket:** resend a spent pre-turn compaction only after the socket stops tracking its response task ([bfe9ab4](https://github.com/icoretech/codex-pooler/commit/bfe9ab436d93d68df5b3f9712ccd604b3f72728c))
* **websocket:** return the public websocket decoder state once for a read without a complete text frame ([292c489](https://github.com/icoretech/codex-pooler/commit/292c48908bce572a562bf1b37f903f03916c920f))
* **websocket:** run the admitted compaction cut with the session's owner on a peer node ([e424f94](https://github.com/icoretech/codex-pooler/commit/e424f9405b61812b2033d912f314f3ccefe2b1e5))
* **websocket:** run the pre-turn compaction cut peer arms on one warmed peer per module ([f2a9bbb](https://github.com/icoretech/codex-pooler/commit/f2a9bbb6fedbadb29317911c7656de118b54ff9b))
* **websocket:** send the next compaction retry once the closed connection's session cleanup finished, and say what the cleanup fence tracks ([c4dd3d6](https://github.com/icoretech/codex-pooler/commit/c4dd3d667a84d8fec5c86ade01df24dbb395fb39))
* **websocket:** send the refused anchored compaction only after the socket stops tracking the first turn's task ([429ce63](https://github.com/icoretech/codex-pooler/commit/429ce63b82f8cc72fc957ccd9ee3c699e9d26991))
* **websocket:** send the settlement-held arm's next retry once the cut compaction has fully settled ([e1819fc](https://github.com/icoretech/codex-pooler/commit/e1819fc2bb587e7ef5a453feed73511b27da07db))
* **websocket:** serve the next /v1 turn after an owner-collected lineage compaction, owner local and on a peer node ([513a010](https://github.com/icoretech/codex-pooler/commit/513a010882f89d656353bb455586d2b4d1f44869))
* **websocket:** settle the dispatched turn of the second same-process socket before both terminate, not after a 15 s owner drain ([5f272b5](https://github.com/icoretech/codex-pooler/commit/5f272b56873a646e1e4fcec2f1b8c278b3965334))
* **websocket:** space the partial-output resend test's row polls ([41c4c96](https://github.com/icoretech/codex-pooler/commit/41c4c9648f9534bd71e78995ff9f82b30b36f11f))
* **websocket:** stop a provider-terminal resend test's Pool owners and read only a test's own owner ([d153c35](https://github.com/icoretech/codex-pooler/commit/d153c35ff4d24a86e3c887d36d5f462405e72d06))
* **websocket:** stop only a test's own Pool owners at teardown instead of every owner in the registry ([13ef6fd](https://github.com/icoretech/codex-pooler/commit/13ef6fd65a2bfc50e8be312cee614f2fd7093d61))
* **websocket:** stop retrying a dropped sandbox checkout in the last two settlement polls ([415fbb2](https://github.com/icoretech/codex-pooler/commit/415fbb21d33d9dbdf4f2bfd9657d1ec87853ab37))
* **websocket:** stop retrying a dropped sandbox checkout in the settlement polls ([e11851e](https://github.com/icoretech/codex-pooler/commit/e11851e99196af1b6436252fd8d3eee4a8932ef7))
* **websocket:** stop the owners of each owner-forwarding continuation test's Pool before the sandbox owner exits ([d8f2cf7](https://github.com/icoretech/codex-pooler/commit/d8f2cf778ea680aa522697a08eb2aed08ec54fbe))
* **websocket:** wait on the rollout-drain T5 terminate and drain tasks with named detection budgets ([bb0e8de](https://github.com/icoretech/codex-pooler/commit/bb0e8de4216903cde635485c40c524e3f6d4a4d2))
* **web:** wait for admin, ingress and sampler messages under named detection budgets ([7b78327](https://github.com/icoretech/codex-pooler/commit/7b78327e7e505665d17e7e646ee53759bdd91c68))


### Miscellaneous Chores

* **codex:** announce and smoke-test the released Codex client 0.156.1 ([c36dbc7](https://github.com/icoretech/codex-pooler/commit/c36dbc71f6c484c5c3a15c3be210ee49b5a92c4e))
* **deps:** present the Pooler upstream identity as Codex 0.156.0 ([f1d6e12](https://github.com/icoretech/codex-pooler/commit/f1d6e12360e4f8be98f06b9caeb95ebe67b17a8f))
* **deps:** update node.js to v26.10.0 ([#428](https://github.com/icoretech/codex-pooler/issues/428)) ([7defb25](https://github.com/icoretech/codex-pooler/commit/7defb25160a88ea3c78e7a9fcc6a8d3536e6e999))
* release 0.9.0 ([1c1e993](https://github.com/icoretech/codex-pooler/commit/1c1e9939a2e17989de413270b1eaadd063658a24))
* **smoke:** default the Codex smoke image to codex-docker 0.156.0, the pinned released client ([495d22c](https://github.com/icoretech/codex-pooler/commit/495d22ced93ffd440b2b949fc6b8d1f4f6236405))
* **toolchain:** move the mise and Renovate Erlang pins to 29.1.1, the release the elixir:1.20.4-otp-29-slim image already carries ([38a224a](https://github.com/icoretech/codex-pooler/commit/38a224a039cf520ba808d8598adcefc7f3819ba6))

## [0.8.6](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.8.5...codex-pooler-v0.8.6) (2026-09-22)


### Features

* **accounting:** record the model the upstream declares it served ([ad89143](https://github.com/icoretech/codex-pooler/commit/ad8914332cf790203d1550fb6a2c617c5b5f397b))
* **accounting:** record the price bucket a settlement was substituted onto ([c996dc3](https://github.com/icoretech/codex-pooler/commit/c996dc38d0aea6ca38b832300b1156c6e8a8f1e2))
* **dev:** let the perf fake upstream carry its request id on the backend's header name ([fa40137](https://github.com/icoretech/codex-pooler/commit/fa401375bc39d17480b0249b1573840ff79b1255))
* **gateway:** keep the reason a native retry observation lost its authority ([f29fc83](https://github.com/icoretech/codex-pooler/commit/f29fc83d888a2c627a5838137d4595b6b9fd8ce4))


### Bug Fixes

* **accounting:** hand a dead-execution recovery's interrupted marker to the outer commit ([13c87c0](https://github.com/icoretech/codex-pooler/commit/13c87c0fe385ff3f8f0ae9cb5f7bb98e41773a1c))
* **accounting:** price a model by its own identifiers before the one the client asked for ([542327c](https://github.com/icoretech/codex-pooler/commit/542327c80217d4d8a85ad88fc0764cf36fd32c3e))
* **accounting:** resolve the scale tier instead of calling it unsupported ([301ba15](https://github.com/icoretech/codex-pooler/commit/301ba1530a639167ae57bb55944a2e4ac5d4d6fe))
* **catalog:** stop model discovery from scoping a sync to a synthetic account id ([e3be8f1](https://github.com/icoretech/codex-pooler/commit/e3be8f199b37e067957aecde2c0dd0ad32b699d1))
* **dev:** declare the upstream request id header in the perf fake's parsed configuration type ([18f6c4f](https://github.com/icoretech/codex-pooler/commit/18f6c4f43169fa9535aeb9a90fbe63a3d208abfb))
* **dev:** interrupt owned QA preparation and batch provenance checks ([318541e](https://github.com/icoretech/codex-pooler/commit/318541eff7a51ee370e7f0b59dfb00ea1ea38f34))
* **gateway:** bound persisted provider header values and drop event headers on public surfaces ([48a0c3e](https://github.com/icoretech/codex-pooler/commit/48a0c3e6510febe375f99f9ec91e53342d28d305))
* **gateway:** canonicalize a reported service tier before bounding it ([78ccf2a](https://github.com/icoretech/codex-pooler/commit/78ccf2ada1075d99edfce405ec38e5a55dabda2b))
* **gateway:** classify a crashed owner as an interrupted turn on every finalizer ([1ac9d85](https://github.com/icoretech/codex-pooler/commit/1ac9d854581ac52d2e0faf3e5130783687b286bc))
* **gateway:** forward the per-request client metadata headers the allowlist missed and align the files bridge ([fa350fb](https://github.com/icoretech/codex-pooler/commit/fa350fb525832519dfceb18c32f0c5dc311047b9))
* **gateway:** keep metadata event headers on public owner forwarding and canonical terminal re-encoding ([1082b64](https://github.com/icoretech/codex-pooler/commit/1082b64f097ae866435b44435f3ab437d394d25e))
* repair two dialyzer contracts the quality gate caught ([4ffa527](https://github.com/icoretech/codex-pooler/commit/4ffa527ada26da6d5dd2912cd7fe96688375cf57))
* **status:** mark a truncated component list instead of cutting mid-name ([deb3e42](https://github.com/icoretech/codex-pooler/commit/deb3e42d967485da2e7bbff77ea1b68d3b799fe6))
* **status:** stop one unreadable incident from stalling every retirement ([85c6b79](https://github.com/icoretech/codex-pooler/commit/85c6b791e670c7e888a2fb14e5e86944bccb1dc2))
* **upstreams:** honor a provider Retry-After on usage polling ([aa42f75](https://github.com/icoretech/codex-pooler/commit/aa42f75d9a882dc9dfdac84cb29326a5f21796ba))
* **upstreams:** require structured refresh-token rejection codes ([505600b](https://github.com/icoretech/codex-pooler/commit/505600b18ebca96538efe6dd1e27589d10e9891d))
* **upstreams:** wait the interval a throttled token refresh was given ([509d474](https://github.com/icoretech/codex-pooler/commit/509d4746c6103ed087f401d6515368f2f607fe46))


### Tests

* **gateway:** pin the native retry witness on admitted tool-continuation and post-compaction resume claims ([22d59b9](https://github.com/icoretech/codex-pooler/commit/22d59b977e2d6a6a076d4e2b2a48da470a946d54))
* recognize absolute kill paths in process absence diagnostics ([ea32759](https://github.com/icoretech/codex-pooler/commit/ea32759449e88da5dc068ac420fd8278a4e60759))
* remove duplicate successful database cleanup probe ([b4d39ae](https://github.com/icoretech/codex-pooler/commit/b4d39aeddd820184a2686c3ecb94df99313181ad))
* **routing:** pin that provider denial outranks positive monthly credits ([934893f](https://github.com/icoretech/codex-pooler/commit/934893f04ffcde437b2c43fe017dd567b43eaaf6))
* skip duration guard registration in CI ([29ef60b](https://github.com/icoretech/codex-pooler/commit/29ef60ba4026e6e71aaa11f2e3970409ee4aad76))
* **status:** pin the incident feed shapes the provider actually sends ([2f2ff86](https://github.com/icoretech/codex-pooler/commit/2f2ff86b52854fde0a2cfc66bb4caa3900ad7034))
* trim fixture setup and await LiveView and websocket teardown ([ba4a15f](https://github.com/icoretech/codex-pooler/commit/ba4a15fb932225b6167c5397df46a92c96653121))
* **upstreams:** pin the refresh rejection classification table ([cabe4f5](https://github.com/icoretech/codex-pooler/commit/cabe4f511f916be4d549c03eb633190d8909b532))


### Miscellaneous Chores

* **deps:** update helm release codex-pooler to v0.8.9 ([4c588e2](https://github.com/icoretech/codex-pooler/commit/4c588e2d274a8e44e9f6524f09017c932981c28e))

## [0.8.5](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.8.4...codex-pooler-v0.8.5) (2026-09-21)


### Features

* **admin:** draw the OAuth callback copy-and-paste step ([c41746b](https://github.com/icoretech/codex-pooler/commit/c41746b620bb08060611e0578e152761133f2bf2))


### Bug Fixes

* **admin:** include deferred events in cockpit metrics type ([ad7dd14](https://github.com/icoretech/codex-pooler/commit/ad7dd14b3762f61ee34e921e4a47ac488d892e31))
* **websocket:** restore declared custom tool namespaces per public turn ([a925cbb](https://github.com/icoretech/codex-pooler/commit/a925cbb1b8897cb30806fd8a70c305d9d2ac0f07))


### Tests

* enforce local duration budgets and remove obsolete rehearsals ([bccc932](https://github.com/icoretech/codex-pooler/commit/bccc93201edf1b43609341d08462ed2e471f6f6e))


### Miscellaneous Chores

* **deps:** update apexcharts to 7.5.1 ([f418683](https://github.com/icoretech/codex-pooler/commit/f41868334ab92092e5cb50f8467c2cca455d8c5e))

## [0.8.4](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.8.3...codex-pooler-v0.8.4) (2026-09-21)


### Bug Fixes

* **admin:** defer expensive account usage reads ([73e4d82](https://github.com/icoretech/codex-pooler/commit/73e4d82d7e3f0efaf945b7daea21975d9a3e6334))
* **admin:** preserve fresh cockpit lifecycle events ([2e843a6](https://github.com/icoretech/codex-pooler/commit/2e843a6c2b8b7c59e73d9f4727cc8fcbcf6680d5))
* **platform:** unbound migration task connection timeouts ([2dbfb62](https://github.com/icoretech/codex-pooler/commit/2dbfb623115b958f2180a0244f882a009b10acd3))


### Tests

* **accounting:** bound retained-history seed statements ([6e1061e](https://github.com/icoretech/codex-pooler/commit/6e1061eb62f9ae2df6851499d900d347676b1626))
* **dev:** recognize the release migration runner ([27e6792](https://github.com/icoretech/codex-pooler/commit/27e67924b7f15e7afe0bd74f4cd1e1e397e173c5))

## [0.8.3](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.8.2...codex-pooler-v0.8.3) (2026-09-21)


### Features

* **access:** add optional active request limit per API key ([233b911](https://github.com/icoretech/codex-pooler/commit/233b911a789b7526594d0f959b9c590ab0463264))
* **accounting:** enforce fleet-wide API key active request limits ([76064c2](https://github.com/icoretech/codex-pooler/commit/76064c288322aeb7b44fa707ddbe2757ec63ab85))
* **admin:** expose active request limits and provisional budget usage ([cc9ea24](https://github.com/icoretech/codex-pooler/commit/cc9ea243ea60669dada66fe3fdc8a476cbe9aced))


### Bug Fixes

* **accounting:** keep pending terminal lookups parameterized ([b25d0c4](https://github.com/icoretech/codex-pooler/commit/b25d0c4134895d6449c831fc1abd89d99352d603))
* **accounting:** persist HTTP 401 for runtime key lifecycle denials ([650c8f6](https://github.com/icoretech/codex-pooler/commit/650c8f6562ea8e3d0cd30470cfeefc697c132685))
* **accounting:** preserve nil active limits for minimal key contexts ([4ac983a](https://github.com/icoretech/codex-pooler/commit/4ac983ae9045d2b89ea5bf854289bd309037b211))
* **accounting:** preserve token pressure across window boundaries ([611b321](https://github.com/icoretech/codex-pooler/commit/611b3219a51a3557da2fe35f19c047c7cf4ad57e))
* **accounting:** sample budget enforcement time under the key lock ([f2d1898](https://github.com/icoretech/codex-pooler/commit/f2d18984a68f130ab7cd8f0ffe9fbd7dee544e4f))
* **admin:** describe API key output estimate floors accurately ([d9d4f33](https://github.com/icoretech/codex-pooler/commit/d9d4f33acb13c23d434659c93c5cabf6272e4fbc))
* **admin:** highlight upstream accounts without pool assignments ([80f5264](https://github.com/icoretech/codex-pooler/commit/80f5264172b053b91d5083cd5532e0c759db2f6e))
* **deps:** upgrade Mint to 1.10.1 ([ce16fd5](https://github.com/icoretech/codex-pooler/commit/ce16fd5e497e3585aad111103ad1cb6685d9629d))
* **gateway:** preserve concurrency denial for retry successors ([a3e0e9b](https://github.com/icoretech/codex-pooler/commit/a3e0e9b7922433e2cc80da32c52d649d53fb3394))
* **gateway:** preserve retryable key concurrency denials across transports ([af40edc](https://github.com/icoretech/codex-pooler/commit/af40edcb7866e25306dc3001983a36752d2c2655))
* **migrations:** backfill API key usage components online ([c3ea594](https://github.com/icoretech/codex-pooler/commit/c3ea5941a46bd17fb1a0d945c979b2168f113bc5))
* **migrations:** bound active request cap schema lock waits ([b102eec](https://github.com/icoretech/codex-pooler/commit/b102eecdac664d880512810095aa8d431f7c3046))
* **upstreams:** normalize saved-reset persistence timestamp precision ([725260e](https://github.com/icoretech/codex-pooler/commit/725260e99f8962141a021520c0437a6bd1bc401e))
* **usage:** distinguish measured tokens from budget pressure ([6810726](https://github.com/icoretech/codex-pooler/commit/6810726103272639fbba2de7ece40b274cd79392))
* **websocket:** fail over exhausted accounts without dropping client sessions ([0c8b628](https://github.com/icoretech/codex-pooler/commit/0c8b62870534c762e507edb7848d03a10c82a3d7))


### Performance Improvements

* **accounting:** restore API key admission throughput ([3094615](https://github.com/icoretech/codex-pooler/commit/309461586a699441525da4fcc84abf9975b8a9ad))


### Tests

* **accounting:** account for retry enforcement clock queries ([2685a66](https://github.com/icoretech/codex-pooler/commit/2685a66df398570f9e2f251e8d8d7ba76bd07552))
* **accounting:** batch retained history fixtures ([6df7f0d](https://github.com/icoretech/codex-pooler/commit/6df7f0df5c3c18c33da618020fd2ee1e7e1f0a8a))
* **admin:** assert bounded API key budget usage reads ([fcee006](https://github.com/icoretech/codex-pooler/commit/fcee0068db3f4676228399d19b759d6cc4e7e02a))
* await websocket owner shutdown before sandbox teardown ([e4c919a](https://github.com/icoretech/codex-pooler/commit/e4c919acc799b1208aee16a61f6a7a3cf00d2290))
* **gateway:** cover ephemeral fork cache identity and session isolation ([73f8557](https://github.com/icoretech/codex-pooler/commit/73f85575311ad4153e54569fd19b52cce966c0fe))
* match websocket terminal ledger rows by kind ([5b7da84](https://github.com/icoretech/codex-pooler/commit/5b7da840e7a309ced9c1b3be86606d2162f0acb6))
* **platform:** refresh peer activity snapshots ([151155f](https://github.com/icoretech/codex-pooler/commit/151155fbbabf04cc9b7f5ad36080ff9a2bb80043))
* **telemetry:** own requeue samples before relay teardown ([3640644](https://github.com/icoretech/codex-pooler/commit/3640644695d51b4d6e5260377f840f1eed3b3de7))
* **websocket:** stop active response tasks before sandbox teardown ([3b39f01](https://github.com/icoretech/codex-pooler/commit/3b39f01bd45c3ba82d8c44b2b1311bb751d39b8e))


### Miscellaneous Chores

* **deps:** lock file maintenance ([9fa3da8](https://github.com/icoretech/codex-pooler/commit/9fa3da830d7761b3ac7197e1a790c0510e76ab91))
* **deps:** update node.js to v26.9.0 ([#419](https://github.com/icoretech/codex-pooler/issues/419)) ([64fa5fb](https://github.com/icoretech/codex-pooler/commit/64fa5fb8509d1a0b0132d8980abf05c06259d90e))

## [0.8.2](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.8.1...codex-pooler-v0.8.2) (2026-09-20)


### Bug Fixes

* **deps:** update dependency daisyui to v5.7.42 ([#411](https://github.com/icoretech/codex-pooler/issues/411)) ([20bfcd2](https://github.com/icoretech/codex-pooler/commit/20bfcd2a433b7d2f754aa7a99f9b0b3f3e8f5b08))
* **dev:** delete leased request graphs before fixture parents ([df4e036](https://github.com/icoretech/codex-pooler/commit/df4e036efd9b3163ba7c7be37e77f0ac04cc8391))
* **gateway:** support unmarked compaction and new public websocket sessions ([a717973](https://github.com/icoretech/codex-pooler/commit/a7179735b4cb83fcd1d0478f338b2763c98219aa))
* **streaming:** reuse decoded native SSE blocks through downstream delivery ([8f30484](https://github.com/icoretech/codex-pooler/commit/8f30484fa5c049b1dc7ef9c6531f0221d3c0b49b))
* **streaming:** scan ignored SSE lines and capped event labels in spans ([776b549](https://github.com/icoretech/codex-pooler/commit/776b5493806f38daca58935fcaf70eb92757903d))
* **websocket:** contain control-path failures and defer slow cleanup ([f71adb4](https://github.com/icoretech/codex-pooler/commit/f71adb4e34064d401fb3bf18bef9e9b194a49a87))

## [0.8.1](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.8.0...codex-pooler-v0.8.1) (2026-09-19)


### Features

* **admin:** distinguish plan badges with satin palettes and activity shine ([8bb63c9](https://github.com/icoretech/codex-pooler/commit/8bb63c966f86ae6375550f9bc623d6fe4d71c87a))


### Bug Fixes

* **admin:** keep saved reset controls inside upstream cards ([12bd4a9](https://github.com/icoretech/codex-pooler/commit/12bd4a97c84c31d7008a9ff031127a6039b2ddef))
* **admin:** keep upstream card headers compact on mobile ([9db21f6](https://github.com/icoretech/codex-pooler/commit/9db21f6fe90a6db2b2aa4d1aa47dbf6be808740c))
* **resets:** recover eligible long-window accounts across mixed exclusions ([da2ed3f](https://github.com/icoretech/codex-pooler/commit/da2ed3f1714178ffa81749596a02f3404eb0215a))
* **streaming:** scan unselected strings and SSE delimiters in spans ([c26b2c2](https://github.com/icoretech/codex-pooler/commit/c26b2c255cd41ee54e8ab93dd9f6763bd71b8e2f))


### Tests

* **admin:** assert compact upstream card header layout ([a4179f3](https://github.com/icoretech/codex-pooler/commit/a4179f3ef3dd3775a20b5fc7c8f1507bbc677131))
* **admin:** assert satin plan badge in pool creation ([abbc1a8](https://github.com/icoretech/codex-pooler/commit/abbc1a864eebdc95199e367ad52b600ea2dec584))
* **gateway:** observe lock relations and isolate cleanup registries ([ab89188](https://github.com/icoretech/codex-pooler/commit/ab89188d0d0744d2c11b67338448bee0a568adca))

## [0.8.0](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.7.8...codex-pooler-v0.8.0) (2026-09-19)


### Features

* **accounting:** name the boundary an interrupted reservation stopped at ([e956979](https://github.com/icoretech/codex-pooler/commit/e956979769e8596eaf50baacc5fe7aa12c4b0cb7))
* **accounting:** say at which boundary a reservation stopped being live ([f40f137](https://github.com/icoretech/codex-pooler/commit/f40f1373e7cf3f80c77733481c0f7c5814b4c69d))
* **admin:** show requested, upstream-reported, and priced service tiers separately ([072580e](https://github.com/icoretech/codex-pooler/commit/072580e19a3046fcdaef6a2e22024129d6afe83d))
* **admin:** show the downstream delivery receipt in the request log attempt drawer ([457bfd9](https://github.com/icoretech/codex-pooler/commit/457bfd9a354b93d3c64cbf3528efe4b69abc01e0))
* **admin:** tell the service tier apart from reasoning effort in request logs ([2601d36](https://github.com/icoretech/codex-pooler/commit/2601d36ec784657d5b46caa41309b7a0b8abcd8a))
* **dev:** provision a pool where routing strategies are observable ([2157734](https://github.com/icoretech/codex-pooler/commit/215773415ad53bd2dcc58fba37391a7d987de46c))
* **diagnostics:** record what a provider said about accepted values ([d348d32](https://github.com/icoretech/codex-pooler/commit/d348d32dc470bfc343ed3b4e75b3afab0855269a))
* **gateway:** derive the Codex routing hint for /v1 requests and keep it out of websocket reuse ([1934516](https://github.com/icoretech/codex-pooler/commit/1934516726d16aee58d2c622ca096fc10a2cec9e))
* **gateway:** forward provider session headers on the native websocket handshake ([b3075a9](https://github.com/icoretech/codex-pooler/commit/b3075a9c379d0cb7f6be65e622ba8b98a59f6981))
* **gateway:** record a downstream delivery receipt for native websocket terminals ([fbe2e71](https://github.com/icoretech/codex-pooler/commit/fbe2e715c812093660a809c879a99729e9bf7b19))
* **gateway:** record the downstream delivery receipt for HTTP SSE turns ([6b31f1d](https://github.com/icoretech/codex-pooler/commit/6b31f1d4944b7a610a292506ba393ac1b16fe43d))
* **gateway:** record which compaction check rejected a stream ([cb26c13](https://github.com/icoretech/codex-pooler/commit/cb26c13ed0cfeddc2d3dc229616c5c3ac0efec4a))
* **gateway:** relay upstream parameter validation rejections to clients ([632d90b](https://github.com/icoretech/codex-pooler/commit/632d90bae53a5f43051cd144bc256bde6be94ba1))
* **gateway:** send a derived session-id upstream for /v1 requests with a prompt_cache_key ([4e32aeb](https://github.com/icoretech/codex-pooler/commit/4e32aeb9db803b05bef1c842a096bd57e936eeb1))
* **jobs:** refresh idle upstream credentials before they expire ([805801d](https://github.com/icoretech/codex-pooler/commit/805801d9b523b9a2afcf55102d72b3207d930f35))
* **platform:** support standard outbound proxies ([087653b](https://github.com/icoretech/codex-pooler/commit/087653b6f6cbc3ece2926296acdaa66fdb5425e6))
* **release:** answer readiness for roles that serve no HTTP ([167f277](https://github.com/icoretech/codex-pooler/commit/167f277458016091526af8b0be0af1f80c395092))
* **routing:** count the affinity writes the ordering fence refuses ([4f67856](https://github.com/icoretech/codex-pooler/commit/4f6785680abc9235e33055f8a1375c21d438edf1))
* **routing:** prefer the previous account when a session is recreated ([1b01245](https://github.com/icoretech/codex-pooler/commit/1b0124542c0637f1d26e658948aa47e61496ff78))
* **routing:** record whether a session's account preference was applied ([1340e3b](https://github.com/icoretech/codex-pooler/commit/1340e3b297ee29491389c9271da27c093c745feb))
* **routing:** steer the next turn away from an account that just overloaded ([12ff75a](https://github.com/icoretech/codex-pooler/commit/12ff75af053e77bacea185bf48209f7f5133e6d3))
* **runtime:** name the blocking transaction when an owner lease renewal times out ([1f48723](https://github.com/icoretech/codex-pooler/commit/1f48723407183c2ceee28316ca8ab2d787828a29))
* **status:** add OpenAI incidents feed and admin surface ([2a0f615](https://github.com/icoretech/codex-pooler/commit/2a0f6155dfa1efc3703b2d6c81c391672e14ebf9))
* **telemetry:** account for relay loss, quiesce consumers at shutdown, and serve folded scrapes ([e5c8347](https://github.com/icoretech/codex-pooler/commit/e5c83472d91f977194406ecf11694c80c39453f5))
* **telemetry:** add postgres relay storage ([156cbdf](https://github.com/icoretech/codex-pooler/commit/156cbdf59bf43c728e000cb65da26c18b5fd39f8))
* **telemetry:** export instance heartbeat failures ([3b37765](https://github.com/icoretech/codex-pooler/commit/3b37765b61654da4c6a9c66c50554d63105bf38a))
* **telemetry:** expose relay via tags ([eb6a436](https://github.com/icoretech/codex-pooler/commit/eb6a436816487be31ec77e7a563f64bd902ebd5e))
* **telemetry:** fail the build when a metric an Oban job emits is undeclared ([c674c93](https://github.com/icoretech/codex-pooler/commit/c674c9346d10aae40346a78df0cb28fab13ee599))
* **telemetry:** key the coverage caveat to the promotion state and pin the shadowed panels ([c37863e](https://github.com/icoretech/codex-pooler/commit/c37863e3ffa65ba007cebfa0c427c6e4b0269439))
* **telemetry:** relay runtime events across roles ([3bfc704](https://github.com/icoretech/codex-pooler/commit/3bfc7049aa845031ac0a384ce4036d6a2ac0546c))
* **telemetry:** require each family's own four promotion gates ([5d8dc4b](https://github.com/icoretech/codex-pooler/commit/5d8dc4b863098181df7e761d9c4702fc1c926957))
* **v1:** send the derived session-id on the /v1 upstream websocket handshake ([2a9d52c](https://github.com/icoretech/codex-pooler/commit/2a9d52c24cf247b840e8eff538f703b20f5d0a83))


### Bug Fixes

* **access:** close idle websockets on API key rotation and fence replay consume on key expiry ([4a8cb72](https://github.com/icoretech/codex-pooler/commit/4a8cb72c0ea9f5f653a59ebfeccd7fb245cc4097))
* **access:** close open websockets when their API key is deleted, expires, moves, or its Pool is disabled ([9ed8990](https://github.com/icoretech/codex-pooler/commit/9ed8990103f10414ffab69cbc007393aabadd4f7))
* **access:** fence rotated keys and notify previous pools ([2ae6dca](https://github.com/icoretech/codex-pooler/commit/2ae6dcaba4d654f2d8be3eb88b6bdf000b155a05))
* **accounting:** admit exact-proof owner crash retries ([0f3a175](https://github.com/icoretech/codex-pooler/commit/0f3a17598d582ea90961eb613143bc506cf42613))
* **accounting:** fingerprint the reason itself, not a truncated rendering ([c346f20](https://github.com/icoretech/codex-pooler/commit/c346f20bc2ae19ad157cdcc6e405c74ff70bf282))
* **accounting:** index rolling costs and stale attempts ([61536cc](https://github.com/icoretech/codex-pooler/commit/61536cc12618ea081903770d56c4827bc5c0d71a))
* **accounting:** keep the delivery receipt projection a runtime reference and accept an already-dead owner in the witness test ([faaaef8](https://github.com/icoretech/codex-pooler/commit/faaaef85659d6cb1f6660bf3be5169dda2a3fe7c))
* **accounting:** let the native turn chain fall open at its bound, not refuse ([0a21ebb](https://github.com/icoretech/codex-pooler/commit/0a21ebbbf52090a69849896916e75b5e5d252b14))
* **accounting:** lock the session before the API key in the websocket resend claim ([cdb307b](https://github.com/icoretech/codex-pooler/commit/cdb307b34035656b14a3da3a48a6cbcb501c69dd))
* **accounting:** preserve idempotency column compatibility ([13da4c7](https://github.com/icoretech/codex-pooler/commit/13da4c7138d82825f0de622a15f246d89e9bd901))
* **accounting:** preserve ledger history when API keys are deleted ([e56a481](https://github.com/icoretech/codex-pooler/commit/e56a4816109a629f02f7a8b7755a0674cb504a91))
* **accounting:** preserve requests when api keys are deleted ([913997f](https://github.com/icoretech/codex-pooler/commit/913997f9360a83c4b1d65d19f3828b18ec6b25c1))
* **accounting:** recover a hard-killed owner's executions through its successor incarnation ([a2f6a8c](https://github.com/icoretech/codex-pooler/commit/a2f6a8c5c74d5c34cd2b79d9bfca4f35dcfe29e7))
* **accounting:** recover attempts whose owning instance stopped reporting ([d508364](https://github.com/icoretech/codex-pooler/commit/d50836453f2ae0ea41d87fa97e4d4a65b84d5585))
* **accounting:** recover ended executions without node connectivity ([15594eb](https://github.com/icoretech/codex-pooler/commit/15594eb3a2d8976561c7b559c19acf6ee04a9f21))
* **accounting:** recover proven-dead turns during resend ([1ca612c](https://github.com/icoretech/codex-pooler/commit/1ca612c7eb0f2f9c16870ab4adb1357668363c0f))
* **accounting:** refuse a second reservation-failure finalization and count its release once ([b973554](https://github.com/icoretech/codex-pooler/commit/b97355422d07ea06b8af42245cccec37e837c798))
* **accounting:** release the reservation a pre-attempt drain leaves outstanding ([18098c8](https://github.com/icoretech/codex-pooler/commit/18098c864d4a9e5f57fd0e5423bfef94576262d5))
* **accounting:** remove raw idempotency key column ([3db6890](https://github.com/icoretech/codex-pooler/commit/3db6890a94ef9db36997dae7911c235d1e590f14))
* **accounting:** retain denied history after key deletion ([ef70637](https://github.com/icoretech/codex-pooler/commit/ef706373b04edfb42b8868140e06ca014d9ab836))
* **accounting:** separate retry successor authority ([6165bb8](https://github.com/icoretech/codex-pooler/commit/6165bb8a77309c8bba5e4eebffc3b6a78984ad32))
* **accounting:** settle reservations when replay preflight closes orphaned requests ([74d4efc](https://github.com/icoretech/codex-pooler/commit/74d4efcdd092cc287d2a7cef4af3b1697b6c2cb2))
* **accounting:** stop using the api_keys row as the per-key reservation mutex ([fdd0951](https://github.com/icoretech/codex-pooler/commit/fdd0951d1ace8c170a053488b7d4b8963702f97c))
* align telemetry tag specs ([4d66a6c](https://github.com/icoretech/codex-pooler/commit/4d66a6cd3ae4777fabb5f1570ea21a62dd4e21a6))
* **auth:** reject unsafe return paths ([1b23517](https://github.com/icoretech/codex-pooler/commit/1b235178bcabef4dc2b9a300663398971e7ef550))
* batch concurrent prometheus scrapes ([ea3f56b](https://github.com/icoretech/codex-pooler/commit/ea3f56b6eb75e755bdd89ee1014e14198eab94a2))
* **catalog:** accept the flat default per-minute pricing shape ([1348a59](https://github.com/icoretech/codex-pooler/commit/1348a596dd5372bf520bd99579c501ef53f5f348))
* **catalog:** derive reasoning metadata from routable sources ([43cc940](https://github.com/icoretech/codex-pooler/commit/43cc940db38313a41ee7283bc24f6f099bef07d3))
* **catalog:** normalize blank reasoning defaults ([62ceac3](https://github.com/icoretech/codex-pooler/commit/62ceac340bc06603e3f72fd9c5b56987e150647c))
* **catalog:** preserve pristine single-source metadata ([06bad6f](https://github.com/icoretech/codex-pooler/commit/06bad6fdf50e5a207e71c0da2d8698fc5da0ffe0))
* **catalog:** resolve reasoning default drift by quota ([a9cf9a3](https://github.com/icoretech/codex-pooler/commit/a9cf9a333328b5cbca01b82246d97f2612fbf511))
* **compaction:** collect native V2 object metadata over websocket ([d1e97dd](https://github.com/icoretech/codex-pooler/commit/d1e97ddd95f54ea9706faf4dedb58b16410f340b))
* **compaction:** mark owner admission before locking reservation rows ([d87bdb7](https://github.com/icoretech/codex-pooler/commit/d87bdb77e130c34fd978504ca316795694a8fd9a))
* **compaction:** preserve native provider terminal retry semantics ([1d6c69f](https://github.com/icoretech/codex-pooler/commit/1d6c69f5843007ca8764490c4e045e8ee8f8bb64))
* **compaction:** separate fresh full-history claims from ordinary turns ([757fc2e](https://github.com/icoretech/codex-pooler/commit/757fc2e530dcdb5a900fece86257034636bf5bf9))
* **compatibility:** align Full supported-value contracts ([d90870d](https://github.com/icoretech/codex-pooler/commit/d90870d4bdceea2d24771f17937ecedcf3f39ff9))
* **dashboard:** generate the heartbeat failure panel ([04fae24](https://github.com/icoretech/codex-pooler/commit/04fae24a85c42ec9365e8ff1ae0c1fcb71fb72c6))
* **deps:** refresh docs dependencies ([7279894](https://github.com/icoretech/codex-pooler/commit/7279894bc4b067f45184a9168732e568f21b3f83))
* **deps:** update daisyUI to 5.7.40 ([5f19f2e](https://github.com/icoretech/codex-pooler/commit/5f19f2eca916da64e8b1decbf547dac2565cfa33))
* **deps:** update dependency apexcharts to v7.2.0 ([#391](https://github.com/icoretech/codex-pooler/issues/391)) ([1a0e49a](https://github.com/icoretech/codex-pooler/commit/1a0e49adc742a79af0f23070cc186146b7fc01fa))
* **deps:** update dependency apexcharts to v7.4.0 ([#403](https://github.com/icoretech/codex-pooler/issues/403)) ([2dd9cee](https://github.com/icoretech/codex-pooler/commit/2dd9cee6436d91a588f82b60a62eb203415baacc))
* **deps:** update dependency daisyui to v5.7.36 ([#385](https://github.com/icoretech/codex-pooler/issues/385)) ([8e6cf4c](https://github.com/icoretech/codex-pooler/commit/8e6cf4c00e1a1b8cdfeb1340d958adbffeb627a1))
* **deps:** update dependency daisyui to v5.7.37 ([#389](https://github.com/icoretech/codex-pooler/issues/389)) ([6e7d709](https://github.com/icoretech/codex-pooler/commit/6e7d7092be4d45c303a48f490a84a8177243a382))
* **deps:** update dependency daisyui to v5.7.38 ([#398](https://github.com/icoretech/codex-pooler/issues/398)) ([b21435f](https://github.com/icoretech/codex-pooler/commit/b21435fa38e8c1bbec5f443c32981214c7b93151))
* **deps:** update docs and frontend packages ([014dff8](https://github.com/icoretech/codex-pooler/commit/014dff8de43c98efb31d39bdbd96768576b820a5))
* **dev:** isolate routing fixture receipts ([fd893e3](https://github.com/icoretech/codex-pooler/commit/fd893e3ae9f4a1f3c77221d33d946e95ecf7900e))
* **dev:** secure routing fixture receipt boundary ([ed81a97](https://github.com/icoretech/codex-pooler/commit/ed81a975184d2effd785948dc3d35adcee320af0))
* **diagnostics:** stop inventing the facts a sanitizer could not find ([524eaa9](https://github.com/icoretech/codex-pooler/commit/524eaa959f1f1f9736e7f49f2dba8b79f207c78b))
* **docs:** put the dashboard panels in the source that generates them ([78126c2](https://github.com/icoretech/codex-pooler/commit/78126c2ad1128c18dd14fe921b8c848de644a53f))
* **finalization:** distinguish a turn that was not found from one that is not there ([9d1427e](https://github.com/icoretech/codex-pooler/commit/9d1427e4bbe41d312cca572e6ffab059da42dc42))
* **gateway:** admit a byte-identical resend after a lifecycle-only upstream stream cut ([d1fb7ef](https://github.com/icoretech/codex-pooler/commit/d1fb7efed4c125f35b9384d6a60650775e70abbb))
* **gateway:** admit a byte-identical websocket resend after a provider terminal failure ([af00377](https://github.com/icoretech/codex-pooler/commit/af00377b633e0e65d7884a647c964b080f0dea1f))
* **gateway:** align direct cleanup result types ([b0fe00d](https://github.com/icoretech/codex-pooler/commit/b0fe00d8abfc96bb3066a99446de72b5e42e733c))
* **gateway:** anchor native resume claims to the latest compaction ([fda2a74](https://github.com/icoretech/codex-pooler/commit/fda2a74a077cae54837f79472bdebb02e1cc85ee))
* **gateway:** bind retry attempts to task cleanup receipts ([faede51](https://github.com/icoretech/codex-pooler/commit/faede51cd49df702efade59f8eab3400cc435688))
* **gateway:** bound lease renewal by its lifecycle budget ([9342adf](https://github.com/icoretech/codex-pooler/commit/9342adfe2eeb09db04196828638ec1a042d4af22))
* **gateway:** bound the idle lifetime of pooled upstream HTTP connections ([299bf37](https://github.com/icoretech/codex-pooler/commit/299bf370a14454950db268873d947d500b2fc4b5))
* **gateway:** classify every authored error type in one place, on both surfaces ([1589693](https://github.com/icoretech/codex-pooler/commit/15896934cbab3145b17789402059f8c975b90f8b))
* **gateway:** classify partial data after compact provider failure ([fa822ba](https://github.com/icoretech/codex-pooler/commit/fa822ba30251376ea2bf3bdc4bbd2900850cd2df))
* **gateway:** continue interrupted HTTP compaction resumes ([8d99979](https://github.com/icoretech/codex-pooler/commit/8d999798a2c0aa7792618aad6b55f49ee0e6a2e0))
* **gateway:** coordinate rollout drain across transports ([394d4a4](https://github.com/icoretech/codex-pooler/commit/394d4a4d61c97029192c0ea8e7a4a58c20d0e791))
* **gateway:** defer retry preamble delivery ([fa77085](https://github.com/icoretech/codex-pooler/commit/fa770857677e5c18a9e66258db0ec9d4db421a8b))
* **gateway:** emit expired-owner interruptions after cleanup commit ([ebd38a2](https://github.com/icoretech/codex-pooler/commit/ebd38a23004e21462fed6cde276805b1b7cbc720))
* **gateway:** fence a native HTTP turn on the turn, not on its body ([e38118d](https://github.com/icoretech/codex-pooler/commit/e38118d3b43d7c47a9f84f1435c5abb1d1f0ca3e))
* **gateway:** fence duplicate native Codex turns on HTTP, not only websocket ([c08c19e](https://github.com/icoretech/codex-pooler/commit/c08c19e55a3ae29b39deb1b012822bf135375c66))
* **gateway:** fence retry after native headers ([add77af](https://github.com/icoretech/codex-pooler/commit/add77af7e4f91f86fc50ced30cb0b92cbc5cfd43))
* **gateway:** finalize a websocket turn whose response task died by exception ([f9bf8f9](https://github.com/icoretech/codex-pooler/commit/f9bf8f9e87894a74f461bfd8322175030ddd6dcb))
* **gateway:** give a drained turn a terminal before its first byte ([3a8ff34](https://github.com/icoretech/codex-pooler/commit/3a8ff343223a91fb24d91c206406f69272f581c1))
* **gateway:** give the native HTTP claim its third arm and chain its fall-open ([24bb38e](https://github.com/icoretech/codex-pooler/commit/24bb38e3f338b0e247c734013beb467449e44066))
* **gateway:** isolate retry response metadata ([9019174](https://github.com/icoretech/codex-pooler/commit/901917413eedfb665e6ecc845f45e21cf37c0e01))
* **gateway:** keep a compacted turn's opener on the bare claim, anchor its resume ([1a3bbf4](https://github.com/icoretech/codex-pooler/commit/1a3bbf42d5ed438de9654ec790d666123de576bf))
* **gateway:** keep final compaction retries replayable ([1ef5250](https://github.com/icoretech/codex-pooler/commit/1ef525063b2cb89a5ae17a46b49a51c52f53f017))
* **gateway:** keep the retry window open across a zero-output preamble ([6000dc9](https://github.com/icoretech/codex-pooler/commit/6000dc99e7d6f0d794f529582e84dbc1744d8db7))
* **gateway:** make the producer side of the recovery markers total too ([1e8bd3f](https://github.com/icoretech/codex-pooler/commit/1e8bd3fbbb633a5f65a5a9a03903b20126281f86))
* **gateway:** name a compacted request by the prefix a retry cannot change ([5be9f02](https://github.com/icoretech/codex-pooler/commit/5be9f025f28ef9049e572bb6d49163db4ef52ef1))
* **gateway:** name a VM, not an address, when claiming a session owner lease ([30f9323](https://github.com/icoretech/codex-pooler/commit/30f9323731e1a86fe5ad60e844c09f13b314e459))
* **gateway:** name every later request of a native turn by its own payload ([72817db](https://github.com/icoretech/codex-pooler/commit/72817dba18660fd15747b3c190b82f958ad0bcfd))
* **gateway:** observe stream completion during deferred drain ([6d9a6a3](https://github.com/icoretech/codex-pooler/commit/6d9a6a39a81e680ac3764ed25bf32452a94afbd9))
* **gateway:** order the provider request-id names like the released client and let frames carry x-oai-request-id ([a849f8a](https://github.com/icoretech/codex-pooler/commit/a849f8a4abeb17c8b44185d8f1f392f934e933be))
* **gateway:** pin a session from the attempt that served, not the one dispatched to ([b0f3129](https://github.com/icoretech/codex-pooler/commit/b0f31295fa5a9bf56e3a818c863005feb094c11c))
* **gateway:** preserve completed turns during key deletion ([c3ea445](https://github.com/icoretech/codex-pooler/commit/c3ea445566624596b1c527d3b597197932c4f268))
* **gateway:** preserve exact death during socket cleanup ([3bef792](https://github.com/icoretech/codex-pooler/commit/3bef79296a117648c59b4b23a4a86e26ec37f38b))
* **gateway:** preserve exact death in owner recovery ([a503ddd](https://github.com/icoretech/codex-pooler/commit/a503ddd8243b416b40ca327caaab5165b4daf1d7))
* **gateway:** read the native endpoint list at runtime, not at compile time ([c95a997](https://github.com/icoretech/codex-pooler/commit/c95a99719405f8210d6c4c12d8c9a212a6261183))
* **gateway:** record native HTTP claim arms ([7cfecdd](https://github.com/icoretech/codex-pooler/commit/7cfecdda1d2a8e3146fe2ba9fc82fc9140b2b939))
* **gateway:** record the provider's x-oai-request-id as the attempt's upstream request id ([cd07768](https://github.com/icoretech/codex-pooler/commit/cd077689260b0e917ccc388dbc1c03e22ab1d35e))
* **gateway:** recover executions stranded by database outages ([7946bbe](https://github.com/icoretech/codex-pooler/commit/7946bbea078d1b72d889ea9775c5f4bb94a94dea))
* **gateway:** refresh and retry HTTP dispatch on a provider 401 instead of passing it to the client ([3f7b4ed](https://github.com/icoretech/codex-pooler/commit/3f7b4ed318547ffdd277c0a2686f6a2cd6d39979))
* **gateway:** reject lease renewal for absent owner incarnations ([36dc245](https://github.com/icoretech/codex-pooler/commit/36dc245627cf4c2b63bcd68c10e6afa5351f0285))
* **gateway:** reject mismatched final compaction items ([8b0c49a](https://github.com/icoretech/codex-pooler/commit/8b0c49a73010be6ac48da73d7aed0421ed85c165))
* **gateway:** relay a provider rejection's type and param instead of flattening them ([0b9f5a9](https://github.com/icoretech/codex-pooler/commit/0b9f5a9644f31c4a7f78182f12741b8c89d7f24b))
* **gateway:** render API-key policy denials on /v1 with their own code and message ([2e6009d](https://github.com/icoretech/codex-pooler/commit/2e6009da3adb47a50f0e87d1b3fa47fa8f054f36))
* **gateway:** render Full validation rejections through the caller-facing mapper ([7d8f6d4](https://github.com/icoretech/codex-pooler/commit/7d8f6d4a575dad8eb51d36f7f1158ddea5c439dc))
* **gateway:** replace absent owner leases before fresh HTTP admission ([ade6931](https://github.com/icoretech/codex-pooler/commit/ade6931e673eb18b99ee6c4fe21eea01d69bf14d))
* **gateway:** retain buffered compaction rejection reasons ([c4bbb57](https://github.com/icoretech/codex-pooler/commit/c4bbb573165db3624000116b07e0ea645595ac63))
* **gateway:** retire delivered websocket executions, close armed replays on task exceptions, keep relayed rejections JSON ([d73f435](https://github.com/icoretech/codex-pooler/commit/d73f4357e77dac9b7df88db054d925c7b3b9b225))
* **gateway:** revoke armed replay entitlements on every terminal arm and mark policy denials by construction ([3974b3d](https://github.com/icoretech/codex-pooler/commit/3974b3d9f0a4f60fc0f5dca1a325507bc7ddd80e))
* **gateway:** rewrite ultra from the selected assignment's levels and release after a terminal attempt ([1df14ac](https://github.com/icoretech/codex-pooler/commit/1df14acc8f9716da7ab2f59fad03e4ca38eecf9b))
* **gateway:** rewrite ultra to the highest catalog level when a model lists no max ([b737f4e](https://github.com/icoretech/codex-pooler/commit/b737f4e6914b388739a4402f934070547b38f35a))
* **gateway:** satisfy the two contracts dialyzer proved were unmet ([412cca2](https://github.com/icoretech/codex-pooler/commit/412cca218c2e6a098ecbce23f7bc115a70a8ea36))
* **gateway:** scope the /v1 derived session-id to the Pool and API key ([dc16bb6](https://github.com/icoretech/codex-pooler/commit/dc16bb6a8acc46f7e9ee95d59b62b98ba389f502))
* **gateway:** separate candidate advancement from authentication retries ([1fb0913](https://github.com/icoretech/codex-pooler/commit/1fb09138fab51f7f98ddd33df35b2d5122b952b2))
* **gateway:** separate websocket compaction resumes ([510c44c](https://github.com/icoretech/codex-pooler/commit/510c44c649e5e93d304953d4961562c99dfa7a1f))
* **gateway:** settle reservations after terminal-attempt task exceptions ([f529804](https://github.com/icoretech/codex-pooler/commit/f529804b0aea4a0d63e552a5d0cfa908608c05a7))
* **gateway:** stop carrying the raw Idempotency-Key into accounting attrs ([b8c55c1](https://github.com/icoretech/codex-pooler/commit/b8c55c18fdf7a90c6727fc318eb35b3213439017))
* **gateway:** stop letting a Pool setting decide how a rejection is named ([27c8a5c](https://github.com/icoretech/codex-pooler/commit/27c8a5cdff37e87fd3bd6b98440ea9ec62667e18))
* **gateway:** treat a contradictory turn metadata header as absent ([b576eaf](https://github.com/icoretech/codex-pooler/commit/b576eafadd638669f6ba75ac26681cae2850eb31))
* **jobs:** let each runtime cleanup step fail without cancelling the rest ([b6236f4](https://github.com/icoretech/codex-pooler/commit/b6236f45a1399cc879a954953209a32db2ba9fa0))
* map full chat validation parameters ([1c18582](https://github.com/icoretech/codex-pooler/commit/1c185829034cae8f6279c4239ee8333c3e53eb30))
* **migrations:** acquire the ledger history rollback locks as a retryable group ([357a389](https://github.com/icoretech/codex-pooler/commit/357a3899a39d5a8ae4513dd6ff466f3607fb442f))
* **migrations:** make 0.8.0 schema changes restartable ([9f76f92](https://github.com/icoretech/codex-pooler/commit/9f76f923495fc9457628df3e7a98aee80a633d97))
* order quota identity locks consistently ([ef04ecf](https://github.com/icoretech/codex-pooler/commit/ef04ecf0d589ab889378f34dc0ed5b38d7f146a4))
* **payloads:** stop injecting a second Lite tools manifest over the client's own ([06798a8](https://github.com/icoretech/codex-pooler/commit/06798a81f12daa0de88e03300925667dd9badd4a))
* **platform:** bound idle pooled connections for every outbound HTTP caller ([41ea506](https://github.com/icoretech/codex-pooler/commit/41ea506a1110ea8e1eb64e341099ef0c3562311f))
* **platform:** identify an instance by its incarnation, not by its node name ([aaf6e03](https://github.com/icoretech/codex-pooler/commit/aaf6e03620ec69633d0421f472be76f5d26437fc))
* **platform:** preserve live owners during heartbeat failure ([8b3a53c](https://github.com/icoretech/codex-pooler/commit/8b3a53cef0bf1be6cd7c4efa9922cb06633afa8f))
* **quota:** order identity advisory and row locks ([08dad3b](https://github.com/icoretech/codex-pooler/commit/08dad3bfbe10adc73166900cdc452bd48173b481))
* **quota:** restore row-first evidence lock ordering ([ae133ac](https://github.com/icoretech/codex-pooler/commit/ae133ac4d975844f084c4482d5e0b9fb20ff9202))
* **quotas:** keep included quota routable ([ddfa2b2](https://github.com/icoretech/codex-pooler/commit/ddfa2b2427d7f408da0326cb3f64b27a837efa8a))
* **quotas:** keep permitted idle windows current ([f29c98f](https://github.com/icoretech/codex-pooler/commit/f29c98f25222a823217b5abdcffcc92ed3632a6a))
* **quotas:** refresh permitted idle account windows ([a693b16](https://github.com/icoretech/codex-pooler/commit/a693b1634b5c6b443d17300ddeec562e253a2210))
* **readiness:** fail closed on unverifiable migration state ([713d6bc](https://github.com/icoretech/codex-pooler/commit/713d6bc6c000347629032c05146e9f6d22f4230d))
* **readiness:** prove the schema on /readyz, not just the connection ([815266c](https://github.com/icoretech/codex-pooler/commit/815266c1a5f121691571c414d57dbf21cd59a611))
* **release:** restore the Repo config after a release task names its connections ([f457282](https://github.com/icoretech/codex-pooler/commit/f4572825ca1f61b4f6aba21f25ed3ec1e36333e1))
* reschedule relay cleanup after errors ([ed80cfc](https://github.com/icoretech/codex-pooler/commit/ed80cfc41cdd970d2e6fca878dfd987b7fdbe95e))
* reschedule relay cleanup on failure ([6deb88b](https://github.com/icoretech/codex-pooler/commit/6deb88b49e91a8375ee92b70034df6348a773fab))
* **routing:** apply reasoning preference after eligibility ([ef073c7](https://github.com/icoretech/codex-pooler/commit/ef073c72ecbba2e641d06e6c5ea17878ebde914e))
* **routing:** govern a whole affinity row by one ordering rule ([bf530d6](https://github.com/icoretech/codex-pooler/commit/bf530d626a033ed0552630494bdbe9431c950c9f))
* **routing:** hash idempotency affinity seeds ([e3783ee](https://github.com/icoretech/codex-pooler/commit/e3783ee0f387b904fc920e81d6feaf29a2908801))
* **routing:** isolate skipped side effects from a caller-owned transaction ([a5c27e7](https://github.com/icoretech/codex-pooler/commit/a5c27e7abfe6b80483c4b10ef7163108c0dc6af0))
* **routing:** keep reasoning variants in canonical capacity ([d3fcb5c](https://github.com/icoretech/codex-pooler/commit/d3fcb5c43e3fb84ccc4494cbe934362d4c3f07ba))
* **routing:** let the ring honour the recreated session's previous account ([8cf1104](https://github.com/icoretech/codex-pooler/commit/8cf11044d988d20dbbabfc325276b72310faf8ea))
* **routing:** preserve overload penalties across concurrent updates ([12ed20d](https://github.com/icoretech/codex-pooler/commit/12ed20d8260de270063c3d5f3f0c6cca97973a12))
* **routing:** retain session assignment after unsuccessful turns ([576a82d](https://github.com/icoretech/codex-pooler/commit/576a82d00a38877203918b45d3c7890f26f455df))
* **routing:** route an explicit reasoning effort to an assignment that has it ([664d31b](https://github.com/icoretech/codex-pooler/commit/664d31b266debe47f0dbc67f4ddb0acd80de9a92))
* **routing:** stop a stale success from clearing overload steering it never saw ([a5ff32b](https://github.com/icoretech/codex-pooler/commit/a5ff32bee01680affef10f7d4267c462fd2c7da5))
* **runtime:** bound the synchronous owner lease renewal lock wait inside Postgres ([ec9f577](https://github.com/icoretech/codex-pooler/commit/ec9f577e53b9786f6ee82adcf555d7deab2f379c))
* **runtime:** defer nested absent-owner outcomes ([ec9c597](https://github.com/icoretech/codex-pooler/commit/ec9c5977c85f3dfb2011ea92a4a3983a186b8ed8))
* **runtime:** drain in-flight HTTP SSE streams at shutdown ([e981410](https://github.com/icoretech/codex-pooler/commit/e981410386d8a5e1dbe869179e83cda67498b962))
* **runtime:** emit absent-owner recovery outcomes ([764b491](https://github.com/icoretech/codex-pooler/commit/764b4913c6bf182e7170d35a99492c56b03ddf27))
* **runtime:** recover absent owners before lease cleanup ([690e55d](https://github.com/icoretech/codex-pooler/commit/690e55d53d78356b6f578f13365afcda615e1eb1))
* **runtime:** reference the lock wait diagnostics type through the owning module ([06c211a](https://github.com/icoretech/codex-pooler/commit/06c211a0b75a878219f8a227553c4fedf57000f2))
* serve stable prometheus snapshots ([fcafe67](https://github.com/icoretech/codex-pooler/commit/fcafe671b79599442a4987e3e33b26848381f51a))
* **status:** make provider feed synchronization durable ([ccbe0df](https://github.com/icoretech/codex-pooler/commit/ccbe0df7ad4f3f56126fc236d51b4c0a2bad5541))
* **status:** normalize numeric RSS timezone offsets to UTC ([f0c8e92](https://github.com/icoretech/codex-pooler/commit/f0c8e9204f535d0e32054eb6003b096b676a8d81))
* **status:** preserve feed errors for worker retries ([d9704fc](https://github.com/icoretech/codex-pooler/commit/d9704fc61fcd202457663e19b1cba75b2fe9b221))
* **status:** reject non-RSS documents before incident synchronization ([5719bb9](https://github.com/icoretech/codex-pooler/commit/5719bb9da85adb468af8403edb5a10a7a06332c3))
* **streaming:** preserve EOF terminal state ([2741d87](https://github.com/icoretech/codex-pooler/commit/2741d873c2907407c8734272e15dca7fab95dcd0))
* **telemetry:** align relay event contracts ([9da0e5a](https://github.com/icoretech/codex-pooler/commit/9da0e5aeb621413fadc499337115987f772e1f67))
* **telemetry:** align relay ids with schema ([7d3d804](https://github.com/icoretech/codex-pooler/commit/7d3d804522157923e8bc952fb4b376339b9f805e))
* **telemetry:** atomically aggregate relay measurements ([8ea2955](https://github.com/icoretech/codex-pooler/commit/8ea2955b5c1523ed0fcda113fb68e6965247d905))
* **telemetry:** attribute a truncated stream body to its transport and route class ([1b04f06](https://github.com/icoretech/codex-pooler/commit/1b04f0614fdb3b6dcd585cbdd7556fd0bf59e984))
* **telemetry:** audit every after-commit emitter as a test, not as prose ([abee58a](https://github.com/icoretech/codex-pooler/commit/abee58a8194935b9d84699933115357bce8e4ebe))
* **telemetry:** avoid relay count double addition ([8abc7f1](https://github.com/icoretech/codex-pooler/commit/8abc7f120d59a5bfc289e00d2bd9bb2bfcec641f))
* **telemetry:** bound relay cleanup batches ([716d9d9](https://github.com/icoretech/codex-pooler/commit/716d9d9885b77ee83132d4be98bde87630ca1839))
* **telemetry:** bound relay label strings and measurement values at the database ([9f29cd0](https://github.com/icoretech/codex-pooler/commit/9f29cd0f4eea7dcd39255faa83dcc9ce9d791149))
* **telemetry:** bound relay measurements ([211bfc7](https://github.com/icoretech/codex-pooler/commit/211bfc72466473a947f055d45e6611296a22f2fc))
* **telemetry:** bound the relay's JSON columns, not only an object's scalars ([393efaa](https://github.com/icoretech/codex-pooler/commit/393efaadbf0d80b4115818cf119db40fe8d5429e))
* **telemetry:** classify a relay refusal by whether the server answered ([3cd8927](https://github.com/icoretech/codex-pooler/commit/3cd89274d782bb5ceb9a5956c2be5dac83ca99d4))
* **telemetry:** classify drained SSE streams as interrupted ([e4f6f7c](https://github.com/icoretech/codex-pooler/commit/e4f6f7cd211396ac94fb865f2488fc2f4a85d1e7))
* **telemetry:** clean relay quality findings ([f5af036](https://github.com/icoretech/codex-pooler/commit/f5af036e60c4fb2d058cc053063b6410aef3e54f))
* **telemetry:** close relay persistence contracts ([e157363](https://github.com/icoretech/codex-pooler/commit/e157363900a589c9e89c798aaf6b328f56b0bfec))
* **telemetry:** count the relay samples storage will never accept ([12c0b96](https://github.com/icoretech/codex-pooler/commit/12c0b961a89fb71cccffd361d0dbafbfe3750a19))
* **telemetry:** decide which family a panel charts from the tokens too ([3803370](https://github.com/icoretech/codex-pooler/commit/3803370705044d83036117f778d9f6841da5bd6f))
* **telemetry:** declare stream outcome via tags ([c23cc7b](https://github.com/icoretech/codex-pooler/commit/c23cc7b03443036690080ee6fcfcf7c73e08aaca))
* **telemetry:** defer all relay finalizer markers ([dc15f94](https://github.com/icoretech/codex-pooler/commit/dc15f94746adeaff894884e39386c15a80d77b7e))
* **telemetry:** defer relay heartbeat until repo ready ([acf7d5d](https://github.com/icoretech/codex-pooler/commit/acf7d5db6152c63d58c9daeaad4ce0b70d0c036e))
* **telemetry:** detect POSIX regex classes structurally ([32f30f2](https://github.com/icoretech/codex-pooler/commit/32f30f2333bde7df2317531d1f45ad2dbe3860c5))
* **telemetry:** fold prometheus distributions without scrapes ([9c0a264](https://github.com/icoretech/codex-pooler/commit/9c0a264a16dbcae67b9ab6be67a003eb5173efe9))
* **telemetry:** guard relay writes by heartbeat ([c659b57](https://github.com/icoretech/codex-pooler/commit/c659b57438cb9ba795997b16d09bb72a759dc94c))
* **telemetry:** harden relay coverage contracts ([77af5e8](https://github.com/icoretech/codex-pooler/commit/77af5e8aa57993cb5bdcda52e5facb87421771fd))
* **telemetry:** include via on all relay metrics ([e61f247](https://github.com/icoretech/codex-pooler/commit/e61f24797a7980df0759ae3945c46680281e3148))
* **telemetry:** isolate relay heartbeat runtime ownership ([01fb33d](https://github.com/icoretech/codex-pooler/commit/01fb33d7365354098c963551049f44c61575811f))
* **telemetry:** keep a convergence whose duration is absurd ([8fdb5b0](https://github.com/icoretech/codex-pooler/commit/8fdb5b08f296e032d7862a2cc9b4995f297821b6))
* **telemetry:** keep an uncompilable __name__ pattern inside the rule ([3891fe9](https://github.com/icoretech/codex-pooler/commit/3891fe90f954cb2ccd89f4c54cbfd934aa074976))
* **telemetry:** label direct events as in-process measurements ([42837f1](https://github.com/icoretech/codex-pooler/commit/42837f1b4f4d6205ba58d8c2b409c02e9ae8289e))
* **telemetry:** let no coverage state or reworded caveat skip the promotion guards ([89c6a41](https://github.com/icoretech/codex-pooler/commit/89c6a41b68cce777627dc0573d901a5cbf2d916a))
* **telemetry:** make promotion retire a family's OBAN_MODE caveat ([b8123b7](https://github.com/icoretech/codex-pooler/commit/b8123b79cf949a99935597e1eb87b3cf0265f7d4))
* **telemetry:** make relay runtime drains loss-aware ([b717345](https://github.com/icoretech/codex-pooler/commit/b7173455c76ff036da69a3b3e7c907e416436003))
* **telemetry:** migrate relay measurements safely ([6eb0ad3](https://github.com/icoretech/codex-pooler/commit/6eb0ad3050820f5e4651c3d0ca7f3cc89f83f66f))
* **telemetry:** name relay flush measurement value ([b7ed4c1](https://github.com/icoretech/codex-pooler/commit/b7ed4c1d438023e447fe8262c2f61fa73877a36c))
* **telemetry:** normalize claimed relay metadata ([a742337](https://github.com/icoretech/codex-pooler/commit/a7423373eb6969c6f2dd3788140d4ed8174102c1))
* **telemetry:** parse RE2 class openings ([6913fdb](https://github.com/icoretech/codex-pooler/commit/6913fdb3a3d5df14c450cf21dcd1255ffe6e62a4))
* **telemetry:** pin the shadow selector to the family the panel charts ([023edd8](https://github.com/icoretech/codex-pooler/commit/023edd8250677a1a17f2400b8e640b6fe0518cfc))
* **telemetry:** point saved-reset fallback at lifecycle metadata ([122e72f](https://github.com/icoretech/codex-pooler/commit/122e72f82c4695fb01fba6c377830442579d4e18))
* **telemetry:** preserve claimed relay rows ([b293d85](https://github.com/icoretech/codex-pooler/commit/b293d85e59ed875be703c7019ebdec25a5cd0cd1))
* **telemetry:** preserve relay cleanup return contracts ([5da07d1](https://github.com/icoretech/codex-pooler/commit/5da07d188b9060e32375d41e69f9124bc5de41c3))
* **telemetry:** preserve relay measurements and via labels ([99b738d](https://github.com/icoretech/codex-pooler/commit/99b738d08b2dfce984ac700a8bcbd71b8cd8d35c))
* **telemetry:** preserve relay samples across roles and database failures ([dca4526](https://github.com/icoretech/codex-pooler/commit/dca452631464537804abb82cff987e5954999b26))
* **telemetry:** preserve relay samples during catch-up ([5da8518](https://github.com/icoretech/codex-pooler/commit/5da8518b9a4cf2932d049fa13ce034d09216c0c7))
* **telemetry:** prune claimed relay rows ([7d9dbb3](https://github.com/icoretech/codex-pooler/commit/7d9dbb3ce9f9cb34b12a687e3c0636f06eefc378))
* **telemetry:** re-emit persisted relay source events ([ae7f2db](https://github.com/icoretech/codex-pooler/commit/ae7f2db6082ade74dfbca8bcdc903fe5d4d0a4e0))
* **telemetry:** reclaim abandoned relay claims ([c0c5753](https://github.com/icoretech/codex-pooler/commit/c0c57531424e4c927ae54a205cf7c8533804519b))
* **telemetry:** reject POSIX regex classes ([a9ee498](https://github.com/icoretech/codex-pooler/commit/a9ee4986b9944ed52cf9a17f8012172b0be9213c))
* **telemetry:** schedule bounded relay retention cleanup ([8c67626](https://github.com/icoretech/codex-pooler/commit/8c676267058541449021b75be21e5b6c87a7ab53))
* **telemetry:** validate dashboard promotion guards ([8737768](https://github.com/icoretech/codex-pooler/commit/8737768e16cb185a8b5eab7f8555f1e72228216b))
* **upstreams:** bound idle pooled connections for every provider HTTP caller ([db8380a](https://github.com/icoretech/codex-pooler/commit/db8380a6e0ef0fb035ab63dcc8cd4269674bdb51))
* **upstreams:** keep unassigned accounts recoverable ([40ac2ea](https://github.com/icoretech/codex-pooler/commit/40ac2ea916fdfea3f8189b3dbad5f42b7c87a4fe))
* **upstreams:** keep valid credentials routable during proactive refresh ([c9d487a](https://github.com/icoretech/codex-pooler/commit/c9d487a9a9027cd52929851388a4223e553cbfba))
* **upstreams:** lock identity advisory keys before rows ([e789de6](https://github.com/icoretech/codex-pooler/commit/e789de6e1c81232378383c75dbf7d16c50c681a9))
* **upstreams:** redact secret material from inspected schemas and pin the class ([a744a22](https://github.com/icoretech/codex-pooler/commit/a744a225be6559154e154394e4fe6c8c1b5a6b72))
* **upstreams:** reject non-object reset detail payloads ([734a2f6](https://github.com/icoretech/codex-pooler/commit/734a2f676a5e3eaebb681f9bc9462f264ece14e3))
* **web:** arm the authorization recheck on every socket, expiry or not ([d676e0a](https://github.com/icoretech/codex-pooler/commit/d676e0acc5cb186ba5b545487587fc5ff163fb9b))
* **websocket:** acknowledge a parked local-owner response task when the socket terminates ([2d21e4f](https://github.com/icoretech/codex-pooler/commit/2d21e4fdce96b8d7c1e176caf6da73fffa3ef3d1))
* **websocket:** acknowledge completions across termination drain phases ([fb29900](https://github.com/icoretech/codex-pooler/commit/fb2990027ee273ecb6ecf28819b4b0a0d0ee2719))
* **websocket:** acknowledge local prewarm completion on proxy sockets ([d640c78](https://github.com/icoretech/codex-pooler/commit/d640c788ef634582fff95d66e43385a895d5bbb7))
* **websocket:** answer the turns a socket discards instead of dropping them ([9c56099](https://github.com/icoretech/codex-pooler/commit/9c560998cefb9b28d512285af48ee8957f10699a))
* **websocket:** bound how long a consumed prepared-frame capability is retained ([3e711d1](https://github.com/icoretech/codex-pooler/commit/3e711d185a2ef1e3efb26adf5e4c5c207ee2949e))
* **websocket:** collect the native compact result outside the diagnostic buffer ([fb0e987](https://github.com/icoretech/codex-pooler/commit/fb0e98747c2011d700fbef883f736682a1e3f13d))
* **websocket:** deliver at most one error frame per native turn on owner-forwarded sockets ([5d375fd](https://github.com/icoretech/codex-pooler/commit/5d375fdc421c8ba9465170d8f31e8c3b494c40ff))
* **websocket:** give back the capability of a frame the socket discards ([e829bf2](https://github.com/icoretech/codex-pooler/commit/e829bf2ff0d2e13b4f519a48e7bb64df530ad847))
* **websocket:** keep a queued frame's capability alive while it waits ([14b7a20](https://github.com/icoretech/codex-pooler/commit/14b7a20599a629835907499d47213aeb344ce3e7))
* **websocket:** keep native websocket turns off HTTP dispatch regardless of the stream flag ([7878f5e](https://github.com/icoretech/codex-pooler/commit/7878f5e256150a00a37a0d184474b1a5ab9462cd))
* **websocket:** keep rejected compact contenders from stealing active delivery ([a81b68e](https://github.com/icoretech/codex-pooler/commit/a81b68ee85eb2baf410e49947afc293ab4411579))
* **websocket:** never relay a provider models ETag on native replay turns ([dc786f9](https://github.com/icoretech/codex-pooler/commit/dc786f93a8d6547900578fd0469ef716d9c2ccd9))
* **websocket:** preserve active stream context on rejected submissions ([93c2371](https://github.com/icoretech/codex-pooler/commit/93c23713a325edcedd8b392b0d31cb7e3f2b0b38))
* **websocket:** settle direct and proxy response tasks when their socket dies unacknowledged ([edbddb8](https://github.com/icoretech/codex-pooler/commit/edbddb82e19c7ecc8e9ef811104fae29a29816a0))
* **websocket:** stop signing a field the socket rewrites after sealing the frame ([ad8ddb2](https://github.com/icoretech/codex-pooler/commit/ad8ddb23f85a7d365559bacf4bb3d4cfdd5fcb07))
* **websocket:** stop telling a client not to retry what it should retry ([5013f70](https://github.com/icoretech/codex-pooler/commit/5013f70f109b1d09b91887b724b781fe7c6bc1e4))


### Performance Improvements

* **access:** take a share lock on api_keys for read-only runtime paths ([4e679c8](https://github.com/icoretech/codex-pooler/commit/4e679c8485cf70c1eb91b1369b024cd40de450ac))
* **gateway:** end socket terminate drains on signals and plumb owner timeouts through recovery ([d3c31cf](https://github.com/icoretech/codex-pooler/commit/d3c31cf39035a6a49f7f7e3c8b9a3566da9b4da4))
* **gateway:** report pre-content owner terminals immediately, plumb handoff timeouts, and bound hosted shell validation ([75c97dd](https://github.com/icoretech/codex-pooler/commit/75c97dd5a9b1b4afeb05eda4f87e8086f6253fd3))


### Tests

* **access:** remove the owner the API key lifecycle tests commit ([1a6d1c7](https://github.com/icoretech/codex-pooler/commit/1a6d1c7062d4a5a1ac52274fc8c5cb582b13af76))
* **accounting:** preserve retry lineage after key deletion ([b72868e](https://github.com/icoretech/codex-pooler/commit/b72868e4335686d8f2fe5247b625082e9e864260))
* **accounting:** use request alias in schema contract ([14a7c1c](https://github.com/icoretech/codex-pooler/commit/14a7c1cc95d089859ff7f863dcca793a8f6e27bb))
* **accounting:** verify both replay-consume and key-deletion orderings ([4f17dea](https://github.com/icoretech/codex-pooler/commit/4f17dea54361a84475067be004adbf9d0dd5f743))
* **accounting:** verify bounded recovery across planner choices ([6963059](https://github.com/icoretech/codex-pooler/commit/696305952edd73816184e7615c45115715e9288c))
* clean committed fixture oban jobs ([bcaf226](https://github.com/icoretech/codex-pooler/commit/bcaf22615cd28d75a3633d1e15ea6c175d099821))
* **compaction:** expose an owned pre-accounting interruption fixture ([9357f27](https://github.com/icoretech/codex-pooler/commit/9357f2763062555caf9bb258e5a89e17d20ef391))
* compare committed guard content across tables ([20ca7d4](https://github.com/icoretech/codex-pooler/commit/20ca7d4fc2c83c50ef06f0065f198a6413383d79))
* **compatibility:** carry the duplicate-turn fence in the route contract ([dd902bd](https://github.com/icoretech/codex-pooler/commit/dd902bd4c70726f4b09df998ecdcc2264bc81cee))
* **compatibility:** move the duplicate-turn contract with the fence it describes ([bdf2ad5](https://github.com/icoretech/codex-pooler/commit/bdf2ad58ccdb89beebe561a478d6bb9bbb002278))
* cover interleaved prometheus scrapes ([0388ea3](https://github.com/icoretech/codex-pooler/commit/0388ea3c40af7c4c8bfecacbf822bd4b141e15c8))
* cover native SSE epoch refusal ([30ebe07](https://github.com/icoretech/codex-pooler/commit/30ebe07ab192eea273298b255419d309437fa133))
* cover native SSE lifecycle refusals ([562b43f](https://github.com/icoretech/codex-pooler/commit/562b43fe0d3d7637376199b3f29181cd3b8c4a2c))
* cover native SSE lifecycle refusals ([fb94d39](https://github.com/icoretech/codex-pooler/commit/fb94d399ee5ed5190593c10eee68af1f2797ed18))
* cover relay cleanup recovery ([ca9128c](https://github.com/icoretech/codex-pooler/commit/ca9128ca5a7a7598c3d486922ccb6055e300780f))
* detect committed metadata changes ([47bc5fa](https://github.com/icoretech/codex-pooler/commit/47bc5fabbdb0e86d7df77a37b6cbe4fa0165ea28))
* **dev-server:** make the lifecycle fixture independent of the host toolchain ([6e04cc1](https://github.com/icoretech/codex-pooler/commit/6e04cc125ac5b07af017dea2206ccd47a28e72ba))
* **dev:** restore an unset owner-forwarding flag by deleting it ([205dbcd](https://github.com/icoretech/codex-pooler/commit/205dbcd2da265a5e0e25ae7d31dab559487d7ec8))
* **drain:** cover the producer of the pre-attempt drain marker ([42bebbd](https://github.com/icoretech/codex-pooler/commit/42bebbdbb25910da997dd12568ec9040a9eb8d95))
* expose committed guard teardown failures ([7cc7ba5](https://github.com/icoretech/codex-pooler/commit/7cc7ba5b26f4873dda333ed0f12d5deb9940b1ae))
* fail a test that leaves committed rows behind, and prove the cleanup paths ([e54e57c](https://github.com/icoretech/codex-pooler/commit/e54e57cc164ef87875e7f8cc01234a53a7f389e8))
* **gateway:** align missing-session continuity contract ([aebb509](https://github.com/icoretech/codex-pooler/commit/aebb509b46d00cc3a7b3770536934da479aea8cf))
* **gateway:** classify duplicate-turn public errors as executable ([7b994f5](https://github.com/icoretech/codex-pooler/commit/7b994f5f404a4788323c4035d537336f26ce7f68))
* **gateway:** cover accounting metadata privacy boundaries ([5147266](https://github.com/icoretech/codex-pooler/commit/51472666d992009841d9f798dc5e81227de549da))
* **gateway:** cover the backend Chat alias under Full and share the quota evidence helper ([fed5780](https://github.com/icoretech/codex-pooler/commit/fed57805307a1639f22f35bcf9095d67977a4792))
* **gateway:** distinguish compaction resume claims ([24c96f7](https://github.com/icoretech/codex-pooler/commit/24c96f7dade3bb57ab4b5a78bc4dc39621c998d4))
* **gateway:** drive the compacted half of the cross-transport cohort ([5083d71](https://github.com/icoretech/codex-pooler/commit/5083d7110fea11d48d117f1d0cc27dcaecba2ca7))
* **gateway:** drive the failover ordering claim instead of asserting it ([17401d9](https://github.com/icoretech/codex-pooler/commit/17401d97880dcad7f201e9b83c895341f8ce3acb))
* **gateway:** drive the rejected-value exclusion through the real /v1/responses path ([4228fd9](https://github.com/icoretech/codex-pooler/commit/4228fd954b358d2f1d7ffb031048742804c7bdeb))
* **gateway:** exercise successful websocket proxy tunnels ([8f68eb1](https://github.com/icoretech/codex-pooler/commit/8f68eb15b6effc53647708da8276cc228037688d))
* **gateway:** give the prepared response.processed test a real API key ([6b51412](https://github.com/icoretech/codex-pooler/commit/6b514123c1e49bda9e6f5cf52828f4412a39f57d))
* **gateway:** give the rejection drain, replay cleanup and saved-reset decision time test-facing knobs ([10b9d7f](https://github.com/icoretech/codex-pooler/commit/10b9d7f813c0ac31d7fabfeec62974a84fd3c319))
* **gateway:** name the failure the expired-owner accounting test drives ([85a1c5e](https://github.com/icoretech/codex-pooler/commit/85a1c5e33ecc7a437baa3692dd3dd329623e3095))
* **gateway:** pin connect failure route health ([f701ab1](https://github.com/icoretech/codex-pooler/commit/f701ab1abbd6f1924938b833addddf467f68a347))
* **gateway:** pin the discriminators both native transports share ([167ce30](https://github.com/icoretech/codex-pooler/commit/167ce30e314c713f6b262ccd962c2a111a19f62b))
* **gateway:** pin websocket connect-failure failover and declare the retry contract ([c682b0f](https://github.com/icoretech/codex-pooler/commit/c682b0f3cb8e1f1bb9401d92d66045ed442f2355))
* **gateway:** pin zero interrupted outcomes for a candidate that goes stale mid-sweep ([c9d127d](https://github.com/icoretech/codex-pooler/commit/c9d127d3fdeeec909e50861f6f0cc0c8ed755174))
* **gateway:** pin zero-spend native retries ([d441c96](https://github.com/icoretech/codex-pooler/commit/d441c965ba7e99561fef5f568ed8cf85f24fd34f))
* **gateway:** prove an idle websocket closes when its key moves to another Pool ([6fb13fc](https://github.com/icoretech/codex-pooler/commit/6fb13fc22b550b0808a24e394ab24d6fa4b3dddf))
* **gateway:** prove the reserved loopback port still refuses before a connect-failover test uses it ([f6566b7](https://github.com/icoretech/codex-pooler/commit/f6566b740a27b03dc6e0211a53766fa048367008))
* **gateway:** seed the cross-transport predecessor the way a websocket writes it ([087803d](https://github.com/icoretech/codex-pooler/commit/087803d34c4ac232ac37daba0e36211caa849736))
* **gateway:** stop the classifier tests depending on which modules loaded first ([984ddb0](https://github.com/icoretech/codex-pooler/commit/984ddb083a42723feb06c37ca5ce153d1f47c162))
* **gateway:** use database time for lease assertions ([5ad646b](https://github.com/icoretech/codex-pooler/commit/5ad646b3045c7a9ff4b664093ff02a42ef2da647))
* **health:** assert completed rollout drain state ([f1eec6c](https://github.com/icoretech/codex-pooler/commit/f1eec6cd336df5a9badc81308cdd2c60196915ce))
* isolate prometheus reporter registry ([bb872b2](https://github.com/icoretech/codex-pooler/commit/bb872b24d15a07f68d258db3b51561cea8d31a6b))
* keep the suite fast, quiet, and off the network ([c53e54e](https://github.com/icoretech/codex-pooler/commit/c53e54ec0b684ec2618dc88f0ba4189e38dafc6e))
* make interleaved prometheus barrier one-shot ([d6934ab](https://github.com/icoretech/codex-pooler/commit/d6934ab82151cc5baff9827c15bb52439ce2c3e4))
* **migrations:** prove hard client exit recovery ([f8d6036](https://github.com/icoretech/codex-pooler/commit/f8d6036a333beffb8c6fcfb65ebd65c355cf8e25))
* **migrations:** reuse the selected Mix runtime in CI ([e4d701b](https://github.com/icoretech/codex-pooler/commit/e4d701bf9ad41678a6eeee9cfd1e5eafa6119f09))
* order committed pool cleanup before cascades ([ec5a4ec](https://github.com/icoretech/codex-pooler/commit/ec5a4ecb469dd0482356e9c42edcb2fd1a730d63))
* order metadata fixture cleanup before cascades ([bbca5c0](https://github.com/icoretech/codex-pooler/commit/bbca5c065a5b6d669f087c422103ba388ccdc9e5))
* **peers:** start timed transitions on the first registry observation ([6292bc7](https://github.com/icoretech/codex-pooler/commit/6292bc7538afc595185b808d8cf4580f590eccfc))
* **platform:** await orderly peer process shutdown ([d9b2888](https://github.com/icoretech/codex-pooler/commit/d9b288850ff1cb29f417e88b67a7940f45b71827))
* **platform:** await peer backend absence before row cleanup ([826d511](https://github.com/icoretech/codex-pooler/commit/826d51144133eb5dadb129dd62dbe92f4b860100))
* **platform:** delete everything the cleanup probe commits, not part of it ([2d2e0ed](https://github.com/icoretech/codex-pooler/commit/2d2e0ed0e520b4e05c4657742fe85f7d557d30d5))
* **platform:** give the replay migration rehearsal and the owner protocol test real detection budgets ([cd65d47](https://github.com/icoretech/codex-pooler/commit/cd65d47c87f51879d67787a51e95c419f5c203f4))
* **platform:** own the peer cleanup order and timeout in one helper each ([f364885](https://github.com/icoretech/codex-pooler/commit/f3648858a4388c8c9f281cd7d776c87146b832de))
* **platform:** pin one Finch pool per distinct outbound option set ([4a17825](https://github.com/icoretech/codex-pooler/commit/4a178255d5b7750de3976126b8e30ed83b471090))
* **platform:** prove liveness cleanup under CI scheduling ([6fcfe6f](https://github.com/icoretech/codex-pooler/commit/6fcfe6f867fb11cfc7898297d8a665dbde0ab214))
* **platform:** stop the superseded peer by identity and end its backends before row cleanup ([0fd3484](https://github.com/icoretech/codex-pooler/commit/0fd34843fc50f36b9a8983595fd90cd4fae15aaa))
* **platform:** track exact peer process identity ([d44f86e](https://github.com/icoretech/codex-pooler/commit/d44f86e99f905309e6aa666a14ddcc0585806d28))
* preserve job selectors before identity cleanup ([8bf4e9e](https://github.com/icoretech/codex-pooler/commit/8bf4e9ef0c49822e1b5b7bc8f5ea97ba72766f0b))
* preserve Oban jobs during committed fixture cleanup ([d96949c](https://github.com/icoretech/codex-pooler/commit/d96949c442df85052b0a4aa22eaa4ac7fa8bc582))
* prove committed cleanup job ownership ([a8dd756](https://github.com/icoretech/codex-pooler/commit/a8dd756fa41c157a1414ab7f931695f9af1579d0))
* **quota:** cover concurrent authorized observers ([340b69c](https://github.com/icoretech/codex-pooler/commit/340b69c309d35c8d18dba841de6d234f68eac73f))
* **quota:** prime the header exhaustion row from the hard-pin recovery test itself ([7ca2782](https://github.com/icoretech/codex-pooler/commit/7ca2782af338a6b16f0f80ca8cd7c50ab740d506))
* **quota:** verify identity advisory locks precede row locks ([7a2ce3e](https://github.com/icoretech/codex-pooler/commit/7a2ce3e7a486dd9cd056bd5abe15aa1ae43257fc))
* register teardown for the rest of the unboxed state, and stop sampling absence once ([1dbbf67](https://github.com/icoretech/codex-pooler/commit/1dbbf677302a4b03a57d55982324661bfc39d0c4))
* register teardown for unboxed state instead of scoping it ([d3ec83a](https://github.com/icoretech/codex-pooler/commit/d3ec83a0bcd5ababfb15028cd1e4f86bcd385460))
* remove what committed fixtures leave behind, and drop run-scoped test databases ([2f5cd11](https://github.com/icoretech/codex-pooler/commit/2f5cd1112718efe4999949f19aa67c1b323c3d22))
* **review:** pin the shutdown marker resolution, relay label keys and the drain tail outcome ([5d22d78](https://github.com/icoretech/codex-pooler/commit/5d22d78e8902a9ba90e36c2ce04ba08de121d855))
* route committed pool cleanup through guard ([36fbed2](https://github.com/icoretech/codex-pooler/commit/36fbed2901f9193d236668176eb8d2e95b38d87c))
* **routing:** expose deterministic rendezvous vectors ([775bd69](https://github.com/icoretech/codex-pooler/commit/775bd694016beb443daa290e635834e780536627))
* **runtime:** close the timing races in the backend HTTP owner lease tests ([28700ab](https://github.com/icoretech/codex-pooler/commit/28700ab2e267175fa42aee4c71a181e4e9d5458c))
* **runtime:** give the local owner crash test its own sandbox connections ([b8020d6](https://github.com/icoretech/codex-pooler/commit/b8020d6ca0e643457806105819287f5058c59095))
* **runtime:** purge the crash test's identity, secrets and assignment rows too ([2bb1d1b](https://github.com/icoretech/codex-pooler/commit/2bb1d1b314e4aad35febbfed0978f45618ea25fd))
* **runtime:** purge the owner crash test's committed rows and scope table-wide assertions to the Pool ([a29aceb](https://github.com/icoretech/codex-pooler/commit/a29aceb328277a8ca30a472bb346712e703e60a2))
* **runtime:** split the owner forwarding websocket test into family files ([1270b46](https://github.com/icoretech/codex-pooler/commit/1270b4626c0d48fb976c08d9187ef63e1b78608b))
* **runtime:** split the websocket controller test into family files ([b752030](https://github.com/icoretech/codex-pooler/commit/b752030157d8142129309663549b1c10bfafaf15))
* **support:** make unboxed cleanup survive the failure that needs it ([10c8db8](https://github.com/icoretech/codex-pooler/commit/10c8db82801c64643559c28522ae337c690b4556))
* **support:** mark the lifecycle log capture helper for dialyzer ([945a1f9](https://github.com/icoretech/codex-pooler/commit/945a1f97afd590fc252a19ab5188e6844290c228))
* **support:** observe expected client closes in the barrier SSE fixture ([fc31bd8](https://github.com/icoretech/codex-pooler/commit/fc31bd8a6cdeff5d3cb9fd581b8a9df6c5daced6))
* **support:** release held FakeUpstream websocket barriers on shutdown instead of waiting out the 15 s kill ([ea9abb0](https://github.com/icoretech/codex-pooler/commit/ea9abb0734e0bedf9d85d99af2e354d458faace1))
* **telemetry:** align via tag expectations ([e6a2b29](https://github.com/icoretech/codex-pooler/commit/e6a2b2934beee2b0eff87a1348eabc870d7d5241))
* **telemetry:** assert relay measurement snapshots ([bcfe5aa](https://github.com/icoretech/codex-pooler/commit/bcfe5aae1dd64fda916b1f090f2f2eab6c9dbd61))
* **telemetry:** avoid global prometheus table assumption ([df2b692](https://github.com/icoretech/codex-pooler/commit/df2b692cdd5967ae921106718abc742e3fb3a05d))
* **telemetry:** cover postgres relay storage ([5f7db56](https://github.com/icoretech/codex-pooler/commit/5f7db56eb7dcaf558cebe05ef53949b3b959578a))
* **telemetry:** cover relay runtime contracts ([d432312](https://github.com/icoretech/codex-pooler/commit/d432312617dfe687e57273913207f8f9c5dbf3ee))
* **telemetry:** cover relay via labels ([1994507](https://github.com/icoretech/codex-pooler/commit/19945077f3b5cf9854a94e40d164123a1e6d8c4f))
* **telemetry:** drive the four relayed families from their real Oban workers ([5925408](https://github.com/icoretech/codex-pooler/commit/5925408c06b7f66a57b2ac1422b16440c818aef3))
* **telemetry:** fail when the operator dashboard queries a metric we dropped ([8addc12](https://github.com/icoretech/codex-pooler/commit/8addc12b9f314067ba26a2d916c0c1d0e63f7c5d))
* **telemetry:** include via in metric samples ([3f9e8cf](https://github.com/icoretech/codex-pooler/commit/3f9e8cf66b36a3d8686317c665f6285d39d197e0))
* **telemetry:** include via on unknown convergence sample ([6ba2286](https://github.com/icoretech/codex-pooler/commit/6ba22862347cf3ec76b1975e045f97b29226dea1))
* **telemetry:** isolate admission samples by emitting process ([1c726e8](https://github.com/icoretech/codex-pooler/commit/1c726e8475fb32c4678640e03412fc1e2b166c04))
* **telemetry:** pin relay lease reclaim semantics ([7257a28](https://github.com/icoretech/codex-pooler/commit/7257a2800e4742d0e7c54f50fb000d9ac55780cc))
* **telemetry:** pin the relay's row shape, cross-node claim and statement bounds ([55f2260](https://github.com/icoretech/codex-pooler/commit/55f226077a59d275c97698e0700b1b35460e4766))
* **telemetry:** probe the relay allowlist by shape, and pin the NOT NULL it rests on ([7b5b1ae](https://github.com/icoretech/codex-pooler/commit/7b5b1ae79c7a84e15d274ed0d894657c8c15fd06))
* **telemetry:** prove a claim skips a row another backend holds instead of waiting on it ([f9cbd33](https://github.com/icoretech/codex-pooler/commit/f9cbd33272fe65fce0d3ec60238945ebfdc64c6b))
* **telemetry:** prove an unscraped node drains its raw samples and counts exactly ([4560ed6](https://github.com/icoretech/codex-pooler/commit/4560ed68e778c18e16b2863b67a00fd0b9173ffe))
* **telemetry:** prove prometheus fold boundaries ([5444337](https://github.com/icoretech/codex-pooler/commit/544433777d872b0cde61d0458fc84cbd3256df22))
* **telemetry:** prove relay cleanup reschedules after failure ([efce9cb](https://github.com/icoretech/codex-pooler/commit/efce9cb4bb8c0803fb9baa49ef41d2baf3dbc02f))
* **telemetry:** prove serialized prometheus folding ([f42beb7](https://github.com/icoretech/codex-pooler/commit/f42beb7c56592d64eee6e7f398121c06b89cfe84))
* **telemetry:** read PromQL label matchers instead of scanning selector text ([c303ba5](https://github.com/icoretech/codex-pooler/commit/c303ba501c688722058732778b08c5ed4954d0e8))
* **telemetry:** read the relay's storable event set off the database ([ada8c8f](https://github.com/icoretech/codex-pooler/commit/ada8c8f33bf96f0c6a278c82acfa2bb92f5316e6))
* **telemetry:** rehearse the relay event storage down and up again ([b7c2d43](https://github.com/icoretech/codex-pooler/commit/b7c2d436a0789528f68739ab45e60daa61a8e6ad))
* **telemetry:** replace the source-scan audit with behavioural coverage ([c40d826](https://github.com/icoretech/codex-pooler/commit/c40d826a662a14ebba07638e10feff004f47cfa1))
* **telemetry:** resolve each promotion test gate against this repository ([fcdbebf](https://github.com/icoretech/codex-pooler/commit/fcdbebf7fa336d1a479ded554b6b54b5361b883f))
* **telemetry:** stabilize prometheus exposition assertion ([9b70002](https://github.com/icoretech/codex-pooler/commit/9b70002876d5b137fffa14d1b152a830778c7fa8))
* **telemetry:** synchronize reporter fold proof ([4c550c4](https://github.com/icoretech/codex-pooler/commit/4c550c4889b9941edc5e953840d5c88682ab1bcd))
* **upstream:** add a native per-frame barrier mode to FakeUpstream and tag strict fixture provenance ([3eabd6a](https://github.com/icoretech/codex-pooler/commit/3eabd6a11d7eab84bc5030a42d99a4a841e10f2f))
* **upstream:** finish the strict FakeUpstream migration ([e6210dd](https://github.com/icoretech/codex-pooler/commit/e6210dda2f22b13516b0fb2a6d48edb0e4fd4a2d))
* **upstream:** migrate one protocol-sensitive test per family to strict fixtures ([5c6d346](https://github.com/icoretech/codex-pooler/commit/5c6d346a254a5c0e60d983ecaa50e9d7b00cd9fd))
* **upstreams:** observe quota timeout before release ([c97512d](https://github.com/icoretech/codex-pooler/commit/c97512d2d5f519ac9d725f5d45ecdc11bd7a5848))
* **upstreams:** pin saved reset retention time ([7a941b2](https://github.com/icoretech/codex-pooler/commit/7a941b24dcdd0561ff97126c286dbd0405b817f6))
* **upstreams:** prove the identity lock order on real backends ([f80f8f6](https://github.com/icoretech/codex-pooler/commit/f80f8f6a02726de9ecc27ad987b4a2d316349daa))
* **v1:** wait for each websocket terminal settlement before the next loop shape ([7a5e64f](https://github.com/icoretech/codex-pooler/commit/7a5e64f19a5800cc4bb0a4680be36069bd80c237))
* verify prometheus distribution folding ([2dacb84](https://github.com/icoretech/codex-pooler/commit/2dacb846e35456069b6f4350ccc7ee18b08a5d99))
* **websocket:** assert the public error type for file conflicts ([e829b59](https://github.com/icoretech/codex-pooler/commit/e829b5998291ffa2718fd96dbe8b6a3b3888afac))
* **websocket:** await response task teardown before detach ([9d3de59](https://github.com/icoretech/codex-pooler/commit/9d3de5901ea21fb29fe6dd752082e341e5b4253a))
* **websocket:** exercise file conflicts through native and public routes ([4b3a608](https://github.com/icoretech/codex-pooler/commit/4b3a6088a47a07e9ff6a65c536c4879e2c384e86))
* **websocket:** name the moment the cancellation watcher can go missing ([e247112](https://github.com/icoretech/codex-pooler/commit/e247112337f743d78a4d8f1c5fea6090efb736cf))
* **websocket:** reach the response queue only through real submissions, and drop the clauses nothing feeds ([13a3c29](https://github.com/icoretech/codex-pooler/commit/13a3c299ee28fdfa33713515d845f19fc2c14b19))
* **websocket:** stop owned sessions before committed fixture cleanup ([6997cec](https://github.com/icoretech/codex-pooler/commit/6997cecca19fb480b3a06657221895b3f1845089))


### Miscellaneous Chores

* **catalog:** refresh the vendored OpenAI pricing snapshot ([d83bc83](https://github.com/icoretech/codex-pooler/commit/d83bc837c98bb6c6978cd7c6628cbda18122ef4f))
* **deps:** update Codex runtime dependencies ([3f77de5](https://github.com/icoretech/codex-pooler/commit/3f77de5af1182024527b3a52220cd82fcd3c7d34))
* **deps:** update Codex runtime to 0.155.1 ([e700719](https://github.com/icoretech/codex-pooler/commit/e70071904c5883a3a28510d100d8160c93886fe8))
* **deps:** update dependency helm/helm to v4.3.0 ([#382](https://github.com/icoretech/codex-pooler/issues/382)) ([423457d](https://github.com/icoretech/codex-pooler/commit/423457d216dc5c5f9c78ab758da59df92581b940))
* **deps:** update dependency node to v26.8.2 ([#383](https://github.com/icoretech/codex-pooler/issues/383)) ([fbdd0c7](https://github.com/icoretech/codex-pooler/commit/fbdd0c7a87ee293baa4477a50cccb5b48f6ef7d1))
* **deps:** update dependency phoenix to v1.8.14 ([#397](https://github.com/icoretech/codex-pooler/issues/397)) ([9aeb98b](https://github.com/icoretech/codex-pooler/commit/9aeb98b32fc940bb83ff7bb892ffcdf09e411105))
* **deps:** update dependency phoenix_live_view to v1.2.12 ([#405](https://github.com/icoretech/codex-pooler/issues/405)) ([91f86e8](https://github.com/icoretech/codex-pooler/commit/91f86e852fe0572654ab09e3dc776552dbaab7dc))
* **deps:** update helm release codex-pooler to v0.8.6 ([#386](https://github.com/icoretech/codex-pooler/issues/386)) ([5a835c4](https://github.com/icoretech/codex-pooler/commit/5a835c463d18aabccdf44f5ad0eaff1f1df556bd))
* **dev:** give the dev database room for parallel partitions ([c75902c](https://github.com/icoretech/codex-pooler/commit/c75902cf6d87c76febfd71670e2823a5a1a8f655))
* **dev:** run the Makefile Mix targets through the pinned toolchain ([d8bd443](https://github.com/icoretech/codex-pooler/commit/d8bd443fcbe0469947644fe1f677c95bb7d6b8ab))
* **format:** format key lifecycle and relay changes ([d1bc923](https://github.com/icoretech/codex-pooler/commit/d1bc923277999ad505baa3f0b4d23f8d49b390f1))
* **mix:** make the format check part of mix quality ([fe80eca](https://github.com/icoretech/codex-pooler/commit/fe80eca8f45e8a352776839f06bd65c021126035))
* move nested aliases to module scope ([7691f56](https://github.com/icoretech/codex-pooler/commit/7691f562e7512de333b39295335246f9a178d527))
* order cleanup test aliases ([f7b7441](https://github.com/icoretech/codex-pooler/commit/f7b74418b157ac5fd4518e051f465fcd862888c3))
* **pricing:** take the 2026-09-12 OpenAI manifest ([b10f5d1](https://github.com/icoretech/codex-pooler/commit/b10f5d11657ee1c217ac1d472ea079b3cc2e463e))
* **quality:** clear Credo aliases and a Dialyzer contract on the release gate ([41f085c](https://github.com/icoretech/codex-pooler/commit/41f085cd3be6662cdc5ea4809564494332579330))
* **references:** remove local checkouts ([6beb5d1](https://github.com/icoretech/codex-pooler/commit/6beb5d1205badcda90d2f7a098015c90d2f126f9))
* reformat ([a8573d3](https://github.com/icoretech/codex-pooler/commit/a8573d3a32d42021a0f774df6a9bf49a0df2d3f9))
* release 0.8.0 ([be981d5](https://github.com/icoretech/codex-pooler/commit/be981d5b38dda42a078deccbc32c33ebe093a356))
* **review:** apply reviewer nits on cleanup logging, contracts and platform docs ([2382675](https://github.com/icoretech/codex-pooler/commit/238267518d6ebef13b2a2b709a413e9ebc871d2e))
* **smoke:** generalize compatibility fixture labels ([62625ff](https://github.com/icoretech/codex-pooler/commit/62625ffd6d0289190ed3eb713bf0d3fc78cde565))
* **smoke:** remove superseded local runner ([08dd576](https://github.com/icoretech/codex-pooler/commit/08dd576c1b2a29317189466a7752d0a9c781eb30))
* **test:** co-locate the barrier reason sets and document two recovery test couplings ([205f682](https://github.com/icoretech/codex-pooler/commit/205f68210391ebc0584d296e72e68ee53e4d5954))

## [0.7.8](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.7.7...codex-pooler-v0.7.8) (2026-09-10)


### Bug Fixes

* **quota:** let confirmed runtime readings supersede a Usage API exhaustion ([821bafe](https://github.com/icoretech/codex-pooler/commit/821bafee10396da8d548c7d5d1bcaafaefacde90))

## [0.7.7](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.7.6...codex-pooler-v0.7.7) (2026-09-10)


### Bug Fixes

* **gateway:** forward the Codex client's session headers on native HTTP routes ([7acc241](https://github.com/icoretech/codex-pooler/commit/7acc2413ff644897d09cbd1a362a8664ff263152))


### Tests

* **payloads:** pin upstream prefix stability across consecutive turns in both serving modes ([2f259e5](https://github.com/icoretech/codex-pooler/commit/2f259e5eecf8cc3ae7dd8e1704ff01d209cde29c))

## [0.7.6](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.7.5...codex-pooler-v0.7.6) (2026-09-10)


### Bug Fixes

* **compaction:** restore websocket envelope after compact projection ([c466d3a](https://github.com/icoretech/codex-pooler/commit/c466d3a7a2704786670324bf251f4223acc2ae30))
* **deps:** update dependency astro to v7.3.2 ([#372](https://github.com/icoretech/codex-pooler/issues/372)) ([b96c6b4](https://github.com/icoretech/codex-pooler/commit/b96c6b4ca6e9a35941e65bd8f21e0913811f70a5))
* **deps:** update dependency daisyui to v5.7.32 ([#373](https://github.com/icoretech/codex-pooler/issues/373)) ([6268de6](https://github.com/icoretech/codex-pooler/commit/6268de68e20153710d058126d8c5bd26dc462d3d))
* **dev:** preserve account bundle transaction boundaries ([5704c68](https://github.com/icoretech/codex-pooler/commit/5704c68b98025208aa9b708e49eff6c69d18f9b0))
* **diagnostics:** retain replay rejection reasons before public error mapping ([1633975](https://github.com/icoretech/codex-pooler/commit/16339755eae8e891559de768ec348efcba579140))
* **images:** retain requested Lite overrides during masked fallback ([2c3545b](https://github.com/icoretech/codex-pooler/commit/2c3545b1065b6d9171028ee8d1493dd98c0c3b03))
* **images:** route masked edits through Full Responses hosts ([508c896](https://github.com/icoretech/codex-pooler/commit/508c896bf8b70d05d132ce3a569fce10e4da05f8))
* **persistence:** lock the session before the turn when completing a turn ([5229a9d](https://github.com/icoretech/codex-pooler/commit/5229a9d1ea7e113db8612784d3c45ff1bfbea54c))
* **quality:** drop unreachable clauses reported by Dialyzer ([4350ed4](https://github.com/icoretech/codex-pooler/commit/4350ed4764a49f6673da2762a91161a381dc09a5))
* **quota:** keep provider measurement and permission evidence coherent ([95e657f](https://github.com/icoretech/codex-pooler/commit/95e657fece51466510131efd88da8b867deaa940))
* **quota:** let confirmed usage readings supersede header exhaustion ([0fb3419](https://github.com/icoretech/codex-pooler/commit/0fb341953e48d9d691ecebdcbc762d619fdb5205))
* **resets:** require corroborated exhaustion before automatic redemption ([cdd1500](https://github.com/icoretech/codex-pooler/commit/cdd1500acd02291fd1023856de921adecb6b6650))
* **resets:** require explained or sustained exhaustion before automatic spend ([abe817c](https://github.com/icoretech/codex-pooler/commit/abe817c27821ddf67e4a2528d25f02d9b313ec5a))
* **upstreams:** fence prepared imports and post-commit publication ([495b861](https://github.com/icoretech/codex-pooler/commit/495b86151a4c7c73fcd0530ccb00cdec805d03f7))
* **upstreams:** preflight credential import batches ([5685b91](https://github.com/icoretech/codex-pooler/commit/5685b91042958621804103f26d293b53ccb2bc1b))
* **websocket:** retire connections after provider connection-limit errors ([4bdd7fd](https://github.com/icoretech/codex-pooler/commit/4bdd7fdb63a0497e195e81b4fae052fe2b05d8ee))


### Performance Improvements

* **upstreams:** bound credential import selection and locking ([15ea269](https://github.com/icoretech/codex-pooler/commit/15ea2696aeb51a1f82435428fc5da85b3374d6b4))


### Tests

* **admin:** order the DataCase alias in the cockpit LiveView test ([7e9ac71](https://github.com/icoretech/codex-pooler/commit/7e9ac71c9fc544a8797746da75303fc73784716e))
* **admin:** release the sandbox before cleaning committed import fixtures ([0ea0721](https://github.com/icoretech/codex-pooler/commit/0ea07211cebe6fe7e9982c51f8237acb4773518f))
* **compression:** cover unsupported tokenizer fail-open lifecycle ([c713a9e](https://github.com/icoretech/codex-pooler/commit/c713a9eb0309ce915b11a127ee4999998e46527d))
* **dev:** extend the compaction smoke fixture for cache fidelity lanes ([70825d6](https://github.com/icoretech/codex-pooler/commit/70825d6795e076e4660e3b729a5b8651237d500e))
* **gateway:** cover recovery and duplicate admission boundaries ([1038262](https://github.com/icoretech/codex-pooler/commit/103826265f47937746780a2ad91ed244c05953b4))
* **quota:** align cockpit priming and hard-pin recovery with confirmed measurements ([8cf536d](https://github.com/icoretech/codex-pooler/commit/8cf536dd5b3195e02676f12f6975c9817a314731))
* **quota:** execute the hard-pin recovery regression and release committed fixtures ([d8e2014](https://github.com/icoretech/codex-pooler/commit/d8e201481a189b98d0d6933ed599b45d62778d6d))
* **runtime:** cover hard-pin recovery after quota denial ([ed9a1ed](https://github.com/icoretech/codex-pooler/commit/ed9a1edb4f304b4f4f85a2e06ab7c160acde0b0c))
* **upstream:** align strict fixture types with scenario failures ([48152be](https://github.com/icoretech/codex-pooler/commit/48152beddd408d97041d74004025d8bc505bf10b))
* **upstreams:** cover prepared import recovery surfaces ([e4b2844](https://github.com/icoretech/codex-pooler/commit/e4b2844ba8a7ea800ae2761acba87fe5ba66674e))
* **websocket:** cover retirement across owner recovery paths ([98bbc66](https://github.com/icoretech/codex-pooler/commit/98bbc662fb80fd4cbdc1bf32fc0f4b6404b8d600))
* **websocket:** enforce finite upstream fixture expectations ([0535d7b](https://github.com/icoretech/codex-pooler/commit/0535d7b323e5cd0a2f36aa0667c56117d2362e5b))
* **websocket:** verify connection retirement across BEAM nodes ([fe776fb](https://github.com/icoretech/codex-pooler/commit/fe776fbcb3287e4a926b2c391ed18c22c7ade877))


### Miscellaneous Chores

* **deps:** update dependency openai/codex to v0.154.0 ([#374](https://github.com/icoretech/codex-pooler/issues/374)) ([ae88a83](https://github.com/icoretech/codex-pooler/commit/ae88a83bc326c87dd252ed5491e282481940b9e8))
* **deps:** update ghcr.io/icoretech/codex-docker docker tag to v0.154.0 ([#377](https://github.com/icoretech/codex-pooler/issues/377)) ([11cd2c4](https://github.com/icoretech/codex-pooler/commit/11cd2c49c36774299dd2cd27b5b07f3fac158265))
* **deps:** update helm release codex-pooler to v0.8.5 ([#375](https://github.com/icoretech/codex-pooler/issues/375)) ([9b1cd27](https://github.com/icoretech/codex-pooler/commit/9b1cd274de1011d062b323c07e6d39e12378e216))

## [0.7.5](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.7.4...codex-pooler-v0.7.5) (2026-09-08)


### Features

* **images:** accept GPT Image 2.5 quality and custom dimensions ([2449eda](https://github.com/icoretech/codex-pooler/commit/2449eda00994310bf8dd2ee86cb308fd366174b7))
* **images:** support GPT Image 2.5 Flare and Sunburst ([55ef04c](https://github.com/icoretech/codex-pooler/commit/55ef04cc7a63cc7eb8aa77aec7939d448e90ce46))
* **pricing:** import expanded tool rates and character billing metadata ([5272fe1](https://github.com/icoretech/codex-pooler/commit/5272fe18307dd60fb7b657f4c8d3fc1c3dda2348))
* **runtime:** add HTTP session lease heartbeat ([542feac](https://github.com/icoretech/codex-pooler/commit/542feac6e54cb8c32dcdc36845acd36b3db80359))


### Bug Fixes

* **gateway:** fence continuity registration by owner token ([c25196c](https://github.com/icoretech/codex-pooler/commit/c25196cf3b421ec8735feaf2da4d1ad0d333e4b8))
* **gateway:** fence stale session completion writes ([9a1978a](https://github.com/icoretech/codex-pooler/commit/9a1978aa938bdf97eda91fdc6a1cc429184a1b1a))
* **gateway:** renew session owner deadlines atomically ([3fcb9ef](https://github.com/icoretech/codex-pooler/commit/3fcb9ef351a2f8d43b52e201cf0355959bf71928))
* **runtime:** preserve deferred results after heartbeat loss ([0968d02](https://github.com/icoretech/codex-pooler/commit/0968d0231f6060b4c296a92c4df607790a4afa76))
* **runtime:** retain owner heartbeat through HTTP streams ([7f4dd65](https://github.com/icoretech/codex-pooler/commit/7f4dd65371b0590b6321eabf04161e5632ac4887))
* **v1:** bound concurrent session startup ([990e6d7](https://github.com/icoretech/codex-pooler/commit/990e6d75182a7ce489a22e3cee8b6eba3ec75c26))
* **v1:** restore schema-bound input compression ([ae4c90e](https://github.com/icoretech/codex-pooler/commit/ae4c90e78c565036a312c567947cf708ee4e80d7))
* **websocket:** preserve compact retries without duplicate dispatch ([2679a93](https://github.com/icoretech/codex-pooler/commit/2679a9302d0e929f18e34bc0d0d230bb9dbfe85a))


### Tests

* **runtime:** cover HTTP owner lease liveness ([c7bbf97](https://github.com/icoretech/codex-pooler/commit/c7bbf97ef30c0d0e6a6adf4f6031d103f583258f))


### Miscellaneous Chores

* **deps:** update helm release codex-pooler to v0.8.3 ([#367](https://github.com/icoretech/codex-pooler/issues/367)) ([6e00d43](https://github.com/icoretech/codex-pooler/commit/6e00d434dd7fd61d010cdf7278476f5ce733c3db))
* **deps:** update helm release codex-pooler to v0.8.4 ([#369](https://github.com/icoretech/codex-pooler/issues/369)) ([376b4f6](https://github.com/icoretech/codex-pooler/commit/376b4f68390d58b98899f581fa010170a6205a92))
* update guides ([b9b2bb6](https://github.com/icoretech/codex-pooler/commit/b9b2bb60131c4804a2e017e60a5ddb65ed8ceb3a))

## [0.7.4](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.7.3...codex-pooler-v0.7.4) (2026-09-07)


### Bug Fixes

* **quotas:** preserve provider permissions and model-specific reset evidence ([8ae4595](https://github.com/icoretech/codex-pooler/commit/8ae4595fc9d5f09eb9e185476d51d7add6180ccd))
* **websocket:** recover interrupted native compaction retries ([42d9f9a](https://github.com/icoretech/codex-pooler/commit/42d9f9aac153c9cebdd7aede2b803beb648f0917))


### Miscellaneous Chores

* **deps:** update helm release codex-pooler to v0.8.0 ([#361](https://github.com/icoretech/codex-pooler/issues/361)) ([2f87d2b](https://github.com/icoretech/codex-pooler/commit/2f87d2bfb9975f19bca9870150251e4163391047))

## [0.7.3](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.7.2...codex-pooler-v0.7.3) (2026-09-07)


### Features

* **admin:** expand retained quota evidence with stable reading snapshots ([3d823e7](https://github.com/icoretech/codex-pooler/commit/3d823e717866ff66863b458c508b81a1f041ea10))
* **admin:** show retained quota source observations in dialogs ([3b021a7](https://github.com/icoretech/codex-pooler/commit/3b021a71337303b924bb8f8024e40deeb74e3a54))


### Bug Fixes

* **deps:** repair Renovate replacements and unblock Codex updates ([436e629](https://github.com/icoretech/codex-pooler/commit/436e629695b415abb5431e82c49d6a38cd673213))


### Tests

* **websocket:** wait for cleanup waiter registration before coordinator exit ([1c38a47](https://github.com/icoretech/codex-pooler/commit/1c38a475ce6b0cb30499d7ea08d9e10e3419cdf0))


### Miscellaneous Chores

* **deps:** update ghcr.io/icoretech/codex-docker docker tag to v0.153.4 ([806f9bb](https://github.com/icoretech/codex-pooler/commit/806f9bbfb99220de810f1b9f35dd083e48b542ba))
* **deps:** update helm release codex-pooler to v0.7.16 ([063e88d](https://github.com/icoretech/codex-pooler/commit/063e88d6858c401181908dbe7357b8a1b458bebd))
* **runtime:** upgrade to Erlang OTP 29 and Elixir 1.20.4 ([e69c07e](https://github.com/icoretech/codex-pooler/commit/e69c07ed09364ab61adf0628c65a59f80f3010bf))

## [0.7.2](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.7.1...codex-pooler-v0.7.2) (2026-09-06)


### Bug Fixes

* **alerts:** separate lifetime delivery receipts from job retry limits ([b882c4c](https://github.com/icoretech/codex-pooler/commit/b882c4ca5d072e63dbe29726a68754f4059603c3))
* **catalog:** finalize malformed discovery sources as failures ([ed3fc2d](https://github.com/icoretech/codex-pooler/commit/ed3fc2d756dae888d221ce7cc8c1833b41f0ed2b))
* **catalog:** validate model fields and advertised modalities ([f219467](https://github.com/icoretech/codex-pooler/commit/f21946725745cc94b45fead2880d8ace5012636c))
* **chat:** preserve compute units in completion usage ([f5376d7](https://github.com/icoretech/codex-pooler/commit/f5376d77a660664502a9d2ab33fc45ffbc7651b1))
* **clustering:** compare pod IP addresses independently of IPv6 spelling ([b5a0b70](https://github.com/icoretech/codex-pooler/commit/b5a0b703e238b70647d26736514fef3c27e7c892))
* **compression:** avoid parsing grouped search matches twice ([1fdc65d](https://github.com/icoretech/codex-pooler/commit/1fdc65dec5bb4ab1e89fcf305cfbf33004709fb6))
* **files:** reject invalid JSON metadata field types ([ee4c737](https://github.com/icoretech/codex-pooler/commit/ee4c7374085255f098f00184822df471309cc89c))
* **images:** reject unsupported model fidelity options ([10b3fb4](https://github.com/icoretech/codex-pooler/commit/10b3fb4b812f2f60115aae4e16776d8d37ca6c99))
* **media:** preserve image masks and validate transcription options ([a30f570](https://github.com/icoretech/codex-pooler/commit/a30f570f714420e1ad411a48f80b9e919a2ad019))
* **pricing:** count canonical rows after service tier alias coalescing ([ff74755](https://github.com/icoretech/codex-pooler/commit/ff7475574261e2b51bc0c4673ef4c83049b99b02))
* **pricing:** reject malformed import URLs before dispatch ([a1f9554](https://github.com/icoretech/codex-pooler/commit/a1f95547c4048905bf7d726e20e80da2972c0afa))
* **quotas:** compare convergence reset timestamps as instants ([f947004](https://github.com/icoretech/codex-pooler/commit/f9470048b3d73dc1d026177c6c35abfd8233d2bf))
* **quotas:** ignore malformed percentages and rate limit containers ([bf646c4](https://github.com/icoretech/codex-pooler/commit/bf646c4d711148d71bfb3867db77e51b3ebf03dd))
* **quotas:** reject invalid relative reset durations ([d0a7b69](https://github.com/icoretech/codex-pooler/commit/d0a7b69f6fb1cf20ca6006dc57e0f66b55b616e3))
* **websocket:** read ownership diagnostics from normalized transport context ([750f3a9](https://github.com/icoretech/codex-pooler/commit/750f3a9be5a12445400eb94056a6817a51b06643))


### Tests

* **accounting:** cover reservation policies file logs and processed acknowledgements ([b9a9e58](https://github.com/icoretech/codex-pooler/commit/b9a9e5865f4fd59acc57beb22dadf445bf3ec69f))
* **catalog:** verify repeated sync and canonical pricing cardinality ([bde17ea](https://github.com/icoretech/codex-pooler/commit/bde17eae2d158e73367402b77559d37fca15b25b))
* **compression:** cover scanner tokenizer and fail-open boundaries ([aa50f27](https://github.com/icoretech/codex-pooler/commit/aa50f279d1007990d6b5cdd7ef70f2a880bf861f))
* **coverage:** exclude development support from Six reports ([d0c5f69](https://github.com/icoretech/codex-pooler/commit/d0c5f69149c223e016a7b3834c863281be532a24))
* **images:** cover GPT Image 2 edit options in Full and Lite ([20b7935](https://github.com/icoretech/codex-pooler/commit/20b793598eb1a3de5a29d7eeab1f2cc1053b228d))
* **quotas:** cover window classification and weekly normalization ([292ba5d](https://github.com/icoretech/codex-pooler/commit/292ba5d2480dfc914452b6fe66e7167f4666d420))
* **runtime:** cover lifecycle transitions and scoped account visibility ([b41b6a7](https://github.com/icoretech/codex-pooler/commit/b41b6a76c9b2a59604a52ec6be6357bb0a5205a7))
* **runtime:** cover upload cleanup authorization and quota refresh boundaries ([51f4a6e](https://github.com/icoretech/codex-pooler/commit/51f4a6e2a22a922e3cde598a6f086cde19b4c916))
* **websocket:** await distributed node shutdown by deadline ([059d01e](https://github.com/icoretech/codex-pooler/commit/059d01e1c7e1939b4dd5dafc609b13462bf02794))
* **websocket:** bind owner fixtures and assert teardown diagnostics ([4d9a409](https://github.com/icoretech/codex-pooler/commit/4d9a40922ad5abcde45737a3dd8320abff8f5f2c))
* **websocket:** observe caller monitor completion after drain ([0abcabb](https://github.com/icoretech/codex-pooler/commit/0abcabba4fe1d9ca3f95c3ab5a8b1b67ddeda729))


### Miscellaneous Chores

* **deps:** lock file maintenance ([69863df](https://github.com/icoretech/codex-pooler/commit/69863dffdafb03faaff2af30040f73720700fb14))
* **deps:** merge Dialyxir 1.4.8 update ([6ce44ee](https://github.com/icoretech/codex-pooler/commit/6ce44ee3b662afdd538d64eee5fb688f99f9a001))
* **deps:** merge documentation lockfile refresh ([eacbf2e](https://github.com/icoretech/codex-pooler/commit/eacbf2e51989e15ecbba5e2d99db16e80bfaf131))
* **deps:** update dependency dialyxir to v1.4.8 ([e8347ed](https://github.com/icoretech/codex-pooler/commit/e8347ed799b6ea2cff2734a42e2a58476b421334))
* **release:** include test and chore commits in release notes ([7bfcd22](https://github.com/icoretech/codex-pooler/commit/7bfcd22f85b829096be175972aa27dbfca07d393))
* update gitignore ([8bf04c3](https://github.com/icoretech/codex-pooler/commit/8bf04c378d2b2a8f2b10c0cd9d5701853728ea13))

## [0.7.1](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.7.0...codex-pooler-v0.7.1) (2026-09-06)


### Bug Fixes

* **compat:** accept flat custom tool definitions in chat requests ([34532e0](https://github.com/icoretech/codex-pooler/commit/34532e060f03cff6ca5a2623c34db105940a2d1f))
* **compat:** normalize Responses-shaped chat requests and tool completion signals ([8def847](https://github.com/icoretech/codex-pooler/commit/8def847026f9a270afe55e64e042d0af01760d0c))
* **compat:** preserve chat tool replay and flat custom call streams ([7ce21db](https://github.com/icoretech/codex-pooler/commit/7ce21dbe07ed00aca4bd92356af3c9dc5b3df661))
* **websocket:** recognize tool continuations after historical compaction ([4ea2c02](https://github.com/icoretech/codex-pooler/commit/4ea2c02943704bc9aff1ed70b72c6eeade6dde92))
* **websocket:** wait for durable finalization before owner drain ([e0ccec5](https://github.com/icoretech/codex-pooler/commit/e0ccec5911fcc292acacbdce434138fe397b71d7))

## [0.7.0](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.6.15...codex-pooler-v0.7.0) (2026-09-06)


### Bug Fixes

* **accounting:** preserve streamed usage and validate collected outcomes ([6418b94](https://github.com/icoretech/codex-pooler/commit/6418b94373acf270163c84954aed4fc276fd1401))
* **accounting:** retain measured usage across SSE event boundaries ([350a5ce](https://github.com/icoretech/codex-pooler/commit/350a5ce17f89ad84d9300c32750489d68fd9c806))
* **admin:** align compact cockpit labels with their icons ([bd55e0f](https://github.com/icoretech/codex-pooler/commit/bd55e0fdc877a2072d822cea0fef888c281eefed))
* **admin:** wrap upstream expiry details on narrow screens ([ed828f9](https://github.com/icoretech/codex-pooler/commit/ed828f92e4e8612d379093d43281a9f784d0250e))
* **api:** distinguish key budget denial from invalid authentication ([3957d54](https://github.com/icoretech/codex-pooler/commit/3957d547384a284a943bb6927ccbee07574696d9))
* **audio:** validate transcription results before settlement ([bb37e56](https://github.com/icoretech/codex-pooler/commit/bb37e56ed8dbb34731ed9ce7a6a9d61f769c6a84))
* **auth:** preserve complete invite results after token publication ([980d226](https://github.com/icoretech/codex-pooler/commit/980d226f10ba8ebc9ca75ba2bd5c38d2a13d8610))
* **catalog:** derive public context length from the native maximum ([c45275c](https://github.com/icoretech/codex-pooler/commit/c45275ca8af767934b98a6540c8c6dc2b0f1d235))
* **catalog:** separate managed client identity from compatibility fixtures ([d92b7b3](https://github.com/icoretech/codex-pooler/commit/d92b7b36ce4616a551ea4a9fb825595cf2ba8a7c))
* **deps:** update dependency @astrojs/starlight to v0.42.0 ([#340](https://github.com/icoretech/codex-pooler/issues/340)) ([692d7f2](https://github.com/icoretech/codex-pooler/commit/692d7f275ef74f98bb1f7ed251f658f2f569fa33))
* **deps:** update dependency astro to v7.3.1 ([#342](https://github.com/icoretech/codex-pooler/issues/342)) ([77d0c17](https://github.com/icoretech/codex-pooler/commit/77d0c17a4bc27e2dec162fe79b897b7da919b980))
* **deps:** update dependency daisyui to v5.7.28 ([#335](https://github.com/icoretech/codex-pooler/issues/335)) ([7ab5765](https://github.com/icoretech/codex-pooler/commit/7ab5765c7e4c914032452abba507977600a6f772))
* **deps:** upgrade Mint to bound HTTP response parsing ([7dac0ea](https://github.com/icoretech/codex-pooler/commit/7dac0eadda1e13db15c2fd421143684b9478097c))
* **dev:** hash logical turn identifiers with SHA256 argument order ([fc09321](https://github.com/icoretech/codex-pooler/commit/fc0932121e9838d83db79dc7ad6eb88adf371a3d))
* **docs:** register the English locale catalog for Starlight ([bcbf67c](https://github.com/icoretech/codex-pooler/commit/bcbf67c17c364781be8129fc60b55c54af21e327))
* **gateway:** bind websocket owners before HTTP stream bridge dispatch ([b25149e](https://github.com/icoretech/codex-pooler/commit/b25149e625436de5a9149fbe30e4a36e65ec12cd))
* **images:** allow generated image tools on Lite serving hosts ([e22dd31](https://github.com/icoretech/codex-pooler/commit/e22dd31866e70635244dac2a11e12b48ba4a6649))
* **images:** dispatch standard image requests through native routes ([e7fe0c9](https://github.com/icoretech/codex-pooler/commit/e7fe0c9eb9d1f309fec43dfbb16fc90a2b55c18e))
* **images:** prefer listed media hosts by catalog priority ([151a99c](https://github.com/icoretech/codex-pooler/commit/151a99c6266b7334bfbdfaac9f89a8ac5d1a0cb4))
* **migrations:** acquire replay table locks as a bounded group ([949cdf7](https://github.com/icoretech/codex-pooler/commit/949cdf780e835311e6713fe88d58ca47317cb69d))
* **quotas:** preserve optional routing and future observation contracts ([c578df6](https://github.com/icoretech/codex-pooler/commit/c578df66d558e1b9eeb5642a2be07fa0523c97a1))
* **quotas:** retain and revalidate explicit account permission ([23fc52a](https://github.com/icoretech/codex-pooler/commit/23fc52a236b239630eec23390b76fcb9ecc45fe0))
* **quotas:** retain fresh credit balances across source changes ([5ebbff8](https://github.com/icoretech/codex-pooler/commit/5ebbff815057610c36f71aaa8a5b0e1ec58535c7))
* **quotas:** retain optional meter identity across label changes ([7b24408](https://github.com/icoretech/codex-pooler/commit/7b244085020928cd4d446efd95c8450cce66a3a1))
* **quotas:** veto threshold resets with current compatible sibling capacity ([51ab46f](https://github.com/icoretech/codex-pooler/commit/51ab46f894429cf3e80adfafb39b0df8a024585d))
* **streaming:** retain delivered native SSE completion ([b7bdec0](https://github.com/icoretech/codex-pooler/commit/b7bdec0a8328048c198053c5278a4cda027e2785))
* **test:** isolate Unix harnesses and stop post-sandbox cache timers ([003bf1b](https://github.com/icoretech/codex-pooler/commit/003bf1b3b9f55fc695adb1a34adc33bbe838912e))
* **types:** allow absent account availability snapshots ([41f1364](https://github.com/icoretech/codex-pooler/commit/41f13640a3bd2ff423dac0e4ab054390aec3be70))
* **upstreams:** bind access token expiry to credential epochs ([c2b8cff](https://github.com/icoretech/codex-pooler/commit/c2b8cfff0fbcac9a29726e8eb840406148323726))
* **upstreams:** recover legacy token expiry during reconciliation ([d33a474](https://github.com/icoretech/codex-pooler/commit/d33a47406d7e45eb3c3e691ab1c8ca1f4cbe5aff))
* **upstreams:** validate lifecycle epochs before preserving credential expiry ([2e2656c](https://github.com/icoretech/codex-pooler/commit/2e2656c113e55efd0361b7e8fa5baeb12c9082af))
* **websocket:** bind cancellation and drain to admitted request lifecycles ([9ebf2cb](https://github.com/icoretech/codex-pooler/commit/9ebf2cb0b7aa50ba1017d4ab2bce572875544324))
* **websocket:** fence client retry successors and owner cleanup ([06350d1](https://github.com/icoretech/codex-pooler/commit/06350d1fc831dde8669d43b40855064fe115d25e))
* **websocket:** preserve bounded native admission diagnostics ([dcb7d12](https://github.com/icoretech/codex-pooler/commit/dcb7d125261ec3965bbbdc3f8edb43c8c34a17bb))
* **websocket:** preserve completed delivery when a successful proxy task closes ([5134546](https://github.com/icoretech/codex-pooler/commit/5134546bdb06acb0111f3f42d5b5f9068efa6feb))
* **websocket:** preserve fragmented upgrades and bound native replay ([0ca577c](https://github.com/icoretech/codex-pooler/commit/0ca577cec21f74a11b6edf5c86a8d227aaf5b502))
* **websocket:** reject explicit unsupported frame types before native fallback ([ab57690](https://github.com/icoretech/codex-pooler/commit/ab57690d4aa227db53ba7d11b84e0a9f54335b3b))
* **websocket:** release unsent owner admissions before retry ([03f38f5](https://github.com/icoretech/codex-pooler/commit/03f38f5ca8a14c1c3c1d1b591e47ed2409345590))


### Performance Improvements

* **admin:** count attempts after selecting recent cockpit events ([f25010c](https://github.com/icoretech/codex-pooler/commit/f25010c1ffe0ff9e6605bbc755374160d7f8590c))


### Miscellaneous Chores

* release 0.7.0 ([33b5482](https://github.com/icoretech/codex-pooler/commit/33b5482ce5975ffd9d42f821ada2de6ba2d28f38))

## [0.6.15](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.6.14...codex-pooler-v0.6.15) (2026-09-03)


### Bug Fixes

* **deps:** update dependency @astrojs/starlight to v0.41.11 ([#336](https://github.com/icoretech/codex-pooler/issues/336)) ([49d0c16](https://github.com/icoretech/codex-pooler/commit/49d0c1659d83ad01bf955f5f756c37b3acd8ee59))

## [0.6.14](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.6.13...codex-pooler-v0.6.14) (2026-09-02)


### Bug Fixes

* **deps:** update dependency apexcharts to v7.1.0 ([#329](https://github.com/icoretech/codex-pooler/issues/329)) ([dd19a65](https://github.com/icoretech/codex-pooler/commit/dd19a653c4da5f377ebfaaf2a3aa3be8e863dbce))
* **deps:** update dependency astro to v7.2.10 ([#333](https://github.com/icoretech/codex-pooler/issues/333)) ([81ad7ac](https://github.com/icoretech/codex-pooler/commit/81ad7ac697cc3ddc60043f69196c6609a5561e96))
* **deps:** update dependency daisyui to v5.7.23 ([#334](https://github.com/icoretech/codex-pooler/issues/334)) ([97899dd](https://github.com/icoretech/codex-pooler/commit/97899dd269e9dbaca46012fc7d9429fa53fadf1d))
* **quotas:** route provider-confirmed windowless accounts ([6976f90](https://github.com/icoretech/codex-pooler/commit/6976f9029a0c4b723655ecd22a98d40e4ff057aa))

## [0.6.13](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.6.12...codex-pooler-v0.6.13) (2026-09-01)


### Features

* **dev:** add a bounded exact-smoke trace preset ([80d1926](https://github.com/icoretech/codex-pooler/commit/80d19263d22602f2197ad1d109b44bfb48d4a4e6))
* **dev:** add full native compaction tracing ([24d7612](https://github.com/icoretech/codex-pooler/commit/24d7612036bf402b837c60438952862f28e58688))


### Bug Fixes

* **catalog:** recover stranded sync jobs ([a8c483e](https://github.com/icoretech/codex-pooler/commit/a8c483eeb0fe32bc22c0f2ded2205f46756817da))
* **compression:** preserve command-backed file reads ([382210f](https://github.com/icoretech/codex-pooler/commit/382210faf135d16411723250fb19848ba3eb3050))
* **deps:** update dependency @astrojs/starlight to v0.41.10 ([#310](https://github.com/icoretech/codex-pooler/issues/310)) ([e678da5](https://github.com/icoretech/codex-pooler/commit/e678da5c8707e65ae23d8baddbe5dcec3db1dc73))
* **deps:** update dependency astro to v7.2.9 ([12e5d6d](https://github.com/icoretech/codex-pooler/commit/12e5d6d1ac9bd66e73ea1863b551e9fe07497dfc))
* **dev:** keep native tracing local and secret-safe ([bf6dab5](https://github.com/icoretech/codex-pooler/commit/bf6dab5488a3f4f00e1919491278347d13156820))
* **dev:** keep trace sensitivity boundaries production-safe ([d3e55d4](https://github.com/icoretech/codex-pooler/commit/d3e55d4370c9d11665c9f8100bd85fe0a5a7ff31))
* **dev:** restart the current runtime before smoke checks ([95c27d2](https://github.com/icoretech/codex-pooler/commit/95c27d2451cfb21e55bb41b37ab67d27e0d0baaf))
* **gateway:** bind native compaction transitions to owner state ([edc3f52](https://github.com/icoretech/codex-pooler/commit/edc3f52b7da27cbc65e138258bd8644bc5f73a92))
* **gateway:** distinguish native tool continuation requests ([3a83940](https://github.com/icoretech/codex-pooler/commit/3a83940a08a4738b5c61c1c219eb56ac3d37c7bc))
* **gateway:** propagate native request correlations ([579ef03](https://github.com/icoretech/codex-pooler/commit/579ef03a7ff1f240615135d1f97d63c16be84360))
* **gateway:** relay native misalignment continuation details ([5d083a4](https://github.com/icoretech/codex-pooler/commit/5d083a4458446ea8793a2da3adbace6f39b6ce17))
* **oban:** keep scheduler stager enabled ([8834ec9](https://github.com/icoretech/codex-pooler/commit/8834ec99f0411a59d8b30537468589ad1ccd30e3))
* **websocket:** add trusted compaction admission controls ([f044fdc](https://github.com/icoretech/codex-pooler/commit/f044fdceb26f9875d9f263edaed2bbcac7646809))
* **websocket:** distinguish reconnect replays from replacements ([3272d7c](https://github.com/icoretech/codex-pooler/commit/3272d7c8b6211890ec5dd42ead5ec8dff6f57cd5))
* **websocket:** preserve native compaction continuations ([8f4c31c](https://github.com/icoretech/codex-pooler/commit/8f4c31c8f360d0635454243d4058345cc5f24a40))
* **websocket:** restore released native turn admission ([08125e0](https://github.com/icoretech/codex-pooler/commit/08125e01f068c4f10bfa194d42954fedd07f8c07))

## [0.6.12](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.6.11...codex-pooler-v0.6.12) (2026-08-28)


### Bug Fixes

* **gateway:** preserve connection-bound compact continuations ([ad2e073](https://github.com/icoretech/codex-pooler/commit/ad2e073a023607dc28c14b50a07bd313241bc3fd))
* **mailer:** verify and classify SMTP TLS handshakes ([b616a7e](https://github.com/icoretech/codex-pooler/commit/b616a7eeb0c12dab30e02c514381abe5a204683d))

## [0.6.11](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.6.10...codex-pooler-v0.6.11) (2026-08-27)


### Features

* **admin:** label Edu Plus and Pro plans ([c3c6936](https://github.com/icoretech/codex-pooler/commit/c3c6936d24b71ca679600d4a689a8ff5482dea1d))

## [0.6.10](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.6.9...codex-pooler-v0.6.10) (2026-08-26)


### Features

* **dev:** add Codex compaction fixture ([1259b25](https://github.com/icoretech/codex-pooler/commit/1259b25f1601613124210b7aa4307aa83e1d27ed))
* **dev:** add request compression fixture mode ([25e7638](https://github.com/icoretech/codex-pooler/commit/25e76388a4429b5d8ff65a1d821ff7103a8034f7))
* **dev:** add reversible smoke fixture lifecycles ([126808c](https://github.com/icoretech/codex-pooler/commit/126808cf76f09f22a6d12ae29ce8cf2f3d721fb1))
* **gateway:** capture compact projection provenance ([0f37693](https://github.com/icoretech/codex-pooler/commit/0f376935407b1e971c4c0837bda5388fb039d44f))
* **observability:** expose compact bridge diagnostics ([a68383b](https://github.com/icoretech/codex-pooler/commit/a68383b89040ffea090e05977a2eea8146c85719))


### Bug Fixes

* **accounting:** omit stale additional usage limits ([8ca1b4e](https://github.com/icoretech/codex-pooler/commit/8ca1b4e7660446492205efa855b87065efe51f1d))
* **admin:** fingerprint colliding quota meter ids ([cf6e0e7](https://github.com/icoretech/codex-pooler/commit/cf6e0e76ba9c61ce7ca64c124488aae7ba383fa8))
* **admin:** hide raw quota labels ([0e3bd0d](https://github.com/icoretech/codex-pooler/commit/0e3bd0db0c85159caad80810d37e426a3756fdb0))
* **admin:** hide stale additional quota rows ([1ab2f8d](https://github.com/icoretech/codex-pooler/commit/1ab2f8d28b102f2cec8083cc40db48014e34e1c1))
* **admin:** render stale quota history ([3c1acbd](https://github.com/icoretech/codex-pooler/commit/3c1acbd6dc38e953ccf065a11ea2cf487c1e8183))
* **admin:** restore compact quota rows ([8f36c4f](https://github.com/icoretech/codex-pooler/commit/8f36c4f8a7bc17b9dd4ac2f70b6298435f48df89))
* **deps:** update dependency @astrojs/starlight to v0.41.8 ([#308](https://github.com/icoretech/codex-pooler/issues/308)) ([a137333](https://github.com/icoretech/codex-pooler/commit/a1373335ddafdf0490b1362d7086e15388115183))
* **deps:** update dependency astro to v7.2.6 ([#300](https://github.com/icoretech/codex-pooler/issues/300)) ([d15cd3e](https://github.com/icoretech/codex-pooler/commit/d15cd3ed6e24c483f3a70d8fe65caf67d66bf68f))
* **deps:** update dependency daisyui to v5.7.22 ([#307](https://github.com/icoretech/codex-pooler/issues/307)) ([3e37d3b](https://github.com/icoretech/codex-pooler/commit/3e37d3b6f22de20914f84b733c9864bcf20d18f9))
* **dev:** redact metered fixture receipts ([5835e3c](https://github.com/icoretech/codex-pooler/commit/5835e3c8a8c25eb5dd1ac9faffe21a39d5dde8f4))
* **dev:** restore metered fixture lifecycle helpers ([0ca70e3](https://github.com/icoretech/codex-pooler/commit/0ca70e3b66872d418a1635b6e4a7dd5a0b74c1c8))
* **files:** send content length for streaming uploads ([fce3ba0](https://github.com/icoretech/codex-pooler/commit/fce3ba054be61ee396f6e8703dd37310b12be78b))
* **gateway:** accept idless OMP compaction replay ([4c86221](https://github.com/icoretech/codex-pooler/commit/4c86221e9f13f1dcb1010f08723ac82b5fbdacc8))
* **gateway:** accept unframed compact terminal SSE ([94fe65d](https://github.com/icoretech/codex-pooler/commit/94fe65dc0d30a9e01b1a7d0b4b6c6dbc8834de80))
* **gateway:** bound native compact rejection errors ([16fc185](https://github.com/icoretech/codex-pooler/commit/16fc185a3524f70c3a427181a274cb2ca376c4ec))
* **gateway:** bridge native websocket compaction triggers ([cb09c7a](https://github.com/icoretech/codex-pooler/commit/cb09c7a7c7451a595b5192742fb234f0977e9f22))
* **gateway:** collect large compact streams incrementally ([5909f3f](https://github.com/icoretech/codex-pooler/commit/5909f3f9802f6cf025bf9c3f11afe7914ced7d8b))
* **gateway:** persist compact projection before dispatch ([6ae1528](https://github.com/icoretech/codex-pooler/commit/6ae15288a2aed4acb58a5ab17700132cf762ea60))
* **gateway:** preserve compact result finalization ([c0fbc42](https://github.com/icoretech/codex-pooler/commit/c0fbc4288e3b167cd6b432e0cc85ad8d0d147254))
* **gateway:** preserve compact terminal diagnostics ([4a523de](https://github.com/icoretech/codex-pooler/commit/4a523deecd18f5bed88c400bddd8803139d4e654))
* **gateway:** preserve native websocket compaction lifecycle ([429329b](https://github.com/icoretech/codex-pooler/commit/429329b7fe82f53b8c9ca0c81e7d3edecf152ffc))
* **gateway:** recognize semantic Codex V2 compaction metadata ([71fc5c2](https://github.com/icoretech/codex-pooler/commit/71fc5c2e701ca393f5b2784ce5f00fa8bc6e591c))
* **gateway:** reject blank native compaction content ([55876dc](https://github.com/icoretech/codex-pooler/commit/55876dc6f9c0b0adb9445b3386968ab5296f8c10))
* **gateway:** reject compact data after terminal event ([7c95107](https://github.com/icoretech/codex-pooler/commit/7c9510730f4bc202d6d6a1328a7c3970d4945df0))
* **gateway:** retain compact tool continuation context ([bc2090a](https://github.com/icoretech/codex-pooler/commit/bc2090aae2422db837153bb72dddac668da153cc))
* **gateway:** retain native compact bridge anchors ([cf01a37](https://github.com/icoretech/codex-pooler/commit/cf01a377b1d7b96e73694bfb9bdccc3a7a0ea710))
* **gateway:** retain opaque compaction anchors ([341feb7](https://github.com/icoretech/codex-pooler/commit/341feb7f9da29091b399050f85e48108747c69e7))
* **gateway:** sanitize compact projection metadata ([17289a0](https://github.com/icoretech/codex-pooler/commit/17289a0831e6f912fdb88966198cb855c1924e1a))
* **jobs:** configure Oban 2.24 release roles ([6901f38](https://github.com/icoretech/codex-pooler/commit/6901f3818d4a4d86a4ad03d5eb6cbdd3561ae30d))
* **jobs:** use Oban 2.24 scheduling options ([bac268a](https://github.com/icoretech/codex-pooler/commit/bac268a2a6473d117bc702d5b1ed6cae75472eb7))
* **quotas:** isolate additional meter identity ([4fab084](https://github.com/icoretech/codex-pooler/commit/4fab084fea5234cbb7cc3fd845377dc516bec356))
* **quotas:** preserve metered quota evidence ([fd75a29](https://github.com/icoretech/codex-pooler/commit/fd75a29fbb4c9e5e4c1acdf33c3a62f338107775))
* **quotas:** simplify meter identity grouping ([0f57b37](https://github.com/icoretech/codex-pooler/commit/0f57b37ffd07e6ecc7aa7de89b51a096faf62fb2))
* **runtime:** preserve backend compact provenance ([1b2fdb0](https://github.com/icoretech/codex-pooler/commit/1b2fdb00ce8f5ddcf4e4248952355593ab4d2fb7))
* **streaming:** accept compact summary aliases ([2bba139](https://github.com/icoretech/codex-pooler/commit/2bba139225e48f2b6a0947f48ddff363938d35a5))
* **telemetry:** retain Prometheus tag callbacks ([1a151f2](https://github.com/icoretech/codex-pooler/commit/1a151f20f545755832c4de80a4a2c0f769a3e2cc))
* **v1:** preserve compact continuation anchors ([c926428](https://github.com/icoretech/codex-pooler/commit/c92642883c56526ce64ecb5fb1750dc354d5cf71))

## [0.6.9](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.6.8...codex-pooler-v0.6.9) (2026-08-23)


### Bug Fixes

* **websocket:** accept exact tracked owner turn frames ([7ecf2b7](https://github.com/icoretech/codex-pooler/commit/7ecf2b746c0410d6849a2733479047be4ed8c9d1))
* **websocket:** acknowledge native owner output probes ([653494f](https://github.com/icoretech/codex-pooler/commit/653494fb0519b096d6ffaf387e4660bb52ee1931))
* **websocket:** bind carried reconnect owner turns ([e87f0e4](https://github.com/icoretech/codex-pooler/commit/e87f0e4b5f71969b0667e2f910d0d6f4e58abed4))
* **websocket:** cancel abandoned tasks before cleanup ([ca15d0e](https://github.com/icoretech/codex-pooler/commit/ca15d0e644010348393eb42663da963eb7b8f53a))
* **websocket:** drain active proxy turns during rollout ([a74442e](https://github.com/icoretech/codex-pooler/commit/a74442e119e2eeb594296bbffe6e604b98ac4cf8))
* **websocket:** preserve completed remote owner sessions on detach ([b7cd6a0](https://github.com/icoretech/codex-pooler/commit/b7cd6a00eea91a3a365b7a153ebd1b9e8118423b))
* **websocket:** preserve natural terminal drain completion ([e73c49e](https://github.com/icoretech/codex-pooler/commit/e73c49e26bca164b071d506661943f9fb2669707))
* **websocket:** preserve remote owner turn timeout budget ([75cb539](https://github.com/icoretech/codex-pooler/commit/75cb539d4e903eb649e811340aa5be6aacea31df))
* **websocket:** reject remote owner drain commands ([2a1ec62](https://github.com/icoretech/codex-pooler/commit/2a1ec62f6802fd8b13814d232d3bfdb2efab4eb1))
* **websocket:** restore mixed-release owner drain behavior ([bcffe8b](https://github.com/icoretech/codex-pooler/commit/bcffe8b178d66cb1606051c2ef8374628aac831e))
* **websocket:** retry continuity alias deadlocks ([d69c859](https://github.com/icoretech/codex-pooler/commit/d69c859f427c5eba0f056900c25b986bae2c2c00))
* **websocket:** serialize rollout cancellation ownership ([6c84efd](https://github.com/icoretech/codex-pooler/commit/6c84efd0ffb087df65e16b9f0aca1bc4b7367b99))
* **websocket:** settle cancellation before watcher dispatch ([5e16cc7](https://github.com/icoretech/codex-pooler/commit/5e16cc79d8cb5295c858671ef9346b20f832976e))
* **websocket:** settle cancelled rollout activities ([36c7b6b](https://github.com/icoretech/codex-pooler/commit/36c7b6b5b868f7b05f610a7b2aba3f2bf5e8d533))
* **websocket:** start admitted proxy turns before delivery ack ([c295bdf](https://github.com/icoretech/codex-pooler/commit/c295bdffb2cfd190a001115d4140d3fb00044eee))
* **websocket:** wait for proxy terminal delivery during drain ([80f0967](https://github.com/icoretech/codex-pooler/commit/80f0967ffe5dbcf47d2389c6f1f041a29df7c502))

## [0.6.8](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.6.7...codex-pooler-v0.6.8) (2026-08-22)


### Bug Fixes

* accept nullable Continue tool strictness ([d2852ab](https://github.com/icoretech/codex-pooler/commit/d2852ab6177f0f8d7d4319c1bb28d4130b0991d9))
* **catalog:** align model info metadata contracts ([1f9e1c5](https://github.com/icoretech/codex-pooler/commit/1f9e1c5f45860d6a116b820f132ce53becc8f92c))
* **catalog:** handle account-scoped context windows ([9b5d084](https://github.com/icoretech/codex-pooler/commit/9b5d08485233e9429640b4938dc9f4a9b93cf551))
* **deps:** update dependency daisyui to v5.7.20 ([#298](https://github.com/icoretech/codex-pooler/issues/298)) ([46181ef](https://github.com/icoretech/codex-pooler/commit/46181efa974dbf441f25341bd3d3a3ed752ec25b))
* **gateway:** accept valid OMP compaction streams ([b57e2eb](https://github.com/icoretech/codex-pooler/commit/b57e2ebca3d11980fae7644139ec9b212b2df047))
* harden compatibility smoke isolation ([c9b14a8](https://github.com/icoretech/codex-pooler/commit/c9b14a8365cc764165c895be9a2b774884a2b5df))

## [0.6.7](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.6.6...codex-pooler-v0.6.7) (2026-08-21)


### Features

* **openai:** support named standalone function outputs ([a04210e](https://github.com/icoretech/codex-pooler/commit/a04210ea723b2bcdf229ae45670578b765a9674f))
* **websocket:** add data-only owner request envelope ([4012684](https://github.com/icoretech/codex-pooler/commit/4012684500a9dc8182ff4b423aed6b098de8c290))


### Bug Fixes

* **deps:** update dependency apexcharts to v6.10.0 ([#294](https://github.com/icoretech/codex-pooler/issues/294)) ([c2ade1c](https://github.com/icoretech/codex-pooler/commit/c2ade1c90158d8d72894325423d8923031b881c7))
* **deps:** update dependency astro to v7.2.3 ([#296](https://github.com/icoretech/codex-pooler/issues/296)) ([81134ec](https://github.com/icoretech/codex-pooler/commit/81134ec5b74166a3bf157c083ae0d8c6ed8dfc7c))
* **deps:** update dependency daisyui to v5.7.18 ([#293](https://github.com/icoretech/codex-pooler/issues/293)) ([d4c6b4a](https://github.com/icoretech/codex-pooler/commit/d4c6b4a11dad556036e56d3d94408e184bec2ff4))
* **dev:** recover symlinked lifecycle receipts ([a2c5d63](https://github.com/icoretech/codex-pooler/commit/a2c5d63128d4bb02027e6532a6e18cbd1900dc6c))
* **gateway:** preserve OMP V2 compaction streaming ([5dd8505](https://github.com/icoretech/codex-pooler/commit/5dd8505f0d6780cbbcbe78c9ab714135076e513c))
* **gateway:** preserve store for V2 compaction bridge ([56a36df](https://github.com/icoretech/codex-pooler/commit/56a36dfa0bd8ebada3db8862b020d92767d68aaa))
* **gateway:** propagate Codex OAuth compute residency ([2b0c2d4](https://github.com/icoretech/codex-pooler/commit/2b0c2d461f299a3109b433f25afe4e7a799caeb8))
* **openai:** validate OMP replay metadata types ([f6143bc](https://github.com/icoretech/codex-pooler/commit/f6143bc83bde76a671564cd91566b79d01bb9945))
* **openai:** validate Responses allowed tool choices ([490c072](https://github.com/icoretech/codex-pooler/commit/490c0720b436c0d217a6813c9f6f387ed061600e))
* **runtime:** revoke websocket sessions after API key disablement ([ed76bbc](https://github.com/icoretech/codex-pooler/commit/ed76bbc43da6d779ed78fc3bf25519280cd1d1e9))
* **test:** stabilize websocket owner regressions ([ed5b305](https://github.com/icoretech/codex-pooler/commit/ed5b3051379f0a245396c82b4716d1345bba76d4))
* **websocket:** contain optional frame observer failures ([7c401f0](https://github.com/icoretech/codex-pooler/commit/7c401f0c97497428c32ea2bfe03660fb67296ca0))
* **websocket:** redact upstream session crash status ([538d7af](https://github.com/icoretech/codex-pooler/commit/538d7afb8e9a476e5c957a046af11408768a3d97))
* **websocket:** retire owners when upstream sessions exit ([ed57455](https://github.com/icoretech/codex-pooler/commit/ed574557e77c6fe26ab8c1f6b0e2e9ef03654248))
* **websocket:** retire settled owners after child exit ([bf1a139](https://github.com/icoretech/codex-pooler/commit/bf1a1393970c9becb98a0aa56ae2bfd800bd94c8))
* **websocket:** scope reset probe owner recovery ([29a61a2](https://github.com/icoretech/codex-pooler/commit/29a61a2001d869e8986a82423b886f45996afd1b))
* **websocket:** tolerate stale owner retirement race ([b728300](https://github.com/icoretech/codex-pooler/commit/b728300d5433e9d54bb8ac47467f9b3081b24c96))
* **websocket:** validate owner request snapshots ([2a6f908](https://github.com/icoretech/codex-pooler/commit/2a6f90856b891c578ada6e4526377082239bd0be))
* **websocket:** version remote owner request submission ([8eff88e](https://github.com/icoretech/codex-pooler/commit/8eff88e6322c9db4768762732f9b8a24295f2946))

## [0.6.6](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.6.5...codex-pooler-v0.6.6) (2026-08-18)


### Features

* **admin:** persist Pool filters in URL ([fd425e2](https://github.com/icoretech/codex-pooler/commit/fd425e26b7f3f15a41d9924226f4b0b909473f27))
* **openai:** accept hosted shell response history ([6a38cc6](https://github.com/icoretech/codex-pooler/commit/6a38cc62ca47d7d0c11a273a438afa3ce60487ed))


### Bug Fixes

* **admin:** canonicalize filter URLs ([385e5c6](https://github.com/icoretech/codex-pooler/commit/385e5c673f2f2b15a9f3c79618734fa278623948))
* **deps:** update dependency apexcharts to v6.9.0 ([#290](https://github.com/icoretech/codex-pooler/issues/290)) ([2b30c30](https://github.com/icoretech/codex-pooler/commit/2b30c309b0e356a3af91fcc5afad56c3c1d0e36b))
* **deps:** update dependency astro to v7.2.2 ([e9b5ec1](https://github.com/icoretech/codex-pooler/commit/e9b5ec15b3af29a1ea7d5525307556eabe669b29))
* **openai:** accept OMP output text replay metadata ([3fa054d](https://github.com/icoretech/codex-pooler/commit/3fa054ddddda234a9e5cd0d61a7c88a765296488))
* **openai:** reject non-object strict schema roots ([5b0df22](https://github.com/icoretech/codex-pooler/commit/5b0df2271d7583f4c17eda1ee71440eaae2b9d0e))

## [0.6.5](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.6.4...codex-pooler-v0.6.5) (2026-08-15)


### Features

* **accounting:** define complete Pool daily rollups ([b2f340b](https://github.com/icoretech/codex-pooler/commit/b2f340bd3d588dfbae85404e38e7796fb67293c7))
* **accounting:** maintain exact Pool daily usage ([0ee6d3a](https://github.com/icoretech/codex-pooler/commit/0ee6d3a6240f4297983c1c24c53091b6612dba77))
* **admin:** observe Pool traffic card visibility ([4ff6e85](https://github.com/icoretech/codex-pooler/commit/4ff6e85feddf0884924901ed15a7fc24482e0441))
* **openai:** accept ultrafast Responses service tier ([c91ce94](https://github.com/icoretech/codex-pooler/commit/c91ce948d9a6088b37a5429b071f60b382f1d4c7))


### Bug Fixes

* **accounting:** fence complete Pool daily rollups ([ee8c2ac](https://github.com/icoretech/codex-pooler/commit/ee8c2ac9983e8c1836ed16157f877f2550b5ecf4))
* **admin:** bound Pool traffic viewport reloads ([76fa929](https://github.com/icoretech/codex-pooler/commit/76fa92975e5ede7214d96e5725e5adf202b3163b))
* **admin:** keep Pool traffic loading viewport-only ([78af2e1](https://github.com/icoretech/codex-pooler/commit/78af2e12acde034980c85de5afe2424ebb095f71))
* **admin:** restore Pool traffic loading feedback ([b898a4c](https://github.com/icoretech/codex-pooler/commit/b898a4ce6bed6a7a4bbf6cdf68db045d7d38d7af))
* **admin:** share Pool traffic projection limits ([d7a812c](https://github.com/icoretech/codex-pooler/commit/d7a812ce92169bb60258bba719823f9bbae9d80b))
* **deps:** update dependency daisyui to v5.7.17 ([#286](https://github.com/icoretech/codex-pooler/issues/286)) ([64b2e10](https://github.com/icoretech/codex-pooler/commit/64b2e10c29300914916ef8b009c245d2dc61d784))
* **dev:** tolerate server exit during stop signals ([5b2f5c1](https://github.com/icoretech/codex-pooler/commit/5b2f5c124ed84b884a2928bda2aa64515e97ec59))
* **gateway:** harden compaction and policy failure handling ([0ad6e4b](https://github.com/icoretech/codex-pooler/commit/0ad6e4b26febe1cc57951097f78570aac28241b4))
* **openai:** bridge public compaction triggers ([a589116](https://github.com/icoretech/codex-pooler/commit/a589116bb733fb53c58520637ea70382c68e6bd3))


### Performance Improvements

* **admin:** lazy-load Pool traffic histograms ([8b585fe](https://github.com/icoretech/codex-pooler/commit/8b585fe804462cd48c382fd4b9fe15c4aa3d56e9))
* **admin:** serve seven-day Pool traffic from rollups ([4d61466](https://github.com/icoretech/codex-pooler/commit/4d61466e4d3df95e1b2ba6e94813853053091fe0))

## [0.6.4](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.6.3...codex-pooler-v0.6.4) (2026-08-14)


### Features

* **admin:** align bulkhead presets with selection cards ([3d05feb](https://github.com/icoretech/codex-pooler/commit/3d05feb00a54b372c10a4d6edd937c15f18aaaf4))
* **admin:** consolidate gateway runtime controls ([4c511df](https://github.com/icoretech/codex-pooler/commit/4c511df33109d7a6ba6e36dca3468909c88f0c03))


### Bug Fixes

* **admin:** assign table separators to group headers ([1448daa](https://github.com/icoretech/codex-pooler/commit/1448daa9ec0683668cdf757d946f94282cce3fd6))
* **admin:** keep runtime group separators single ([0d0f496](https://github.com/icoretech/codex-pooler/commit/0d0f4963978f4b1d8d432e1b50e6c6cdf530ab29))
* **admin:** let runtime descriptions use column width ([ab78076](https://github.com/icoretech/codex-pooler/commit/ab780767ac8cf1c8edaf1dbbb775b8bead709c71))
* **ci:** isolate quality analysis from development builds ([0119651](https://github.com/icoretech/codex-pooler/commit/01196510017db957cafcfd2a2c516696fbdbe2b1))
* **test:** target consolidated gateway settings form ([facc726](https://github.com/icoretech/codex-pooler/commit/facc726543b84f945acf33e8aa9d1ae71da4349e))
* **test:** warm settings cache before sandbox ownership ([157b812](https://github.com/icoretech/codex-pooler/commit/157b8121d683baf9437a67d1e82cfc11625a70ec))

## [0.6.3](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.6.2...codex-pooler-v0.6.3) (2026-08-14)


### Features

* **admin:** add structured bulkhead editor ([86c735d](https://github.com/icoretech/codex-pooler/commit/86c735d7c99f989eacf5af23b6e94e85a2d9c7b5))
* **gateway:** support Responses WebSocket stream IDs ([302f9f6](https://github.com/icoretech/codex-pooler/commit/302f9f69fa439744b372951b7be7d1598c528932))


### Bug Fixes

* **gateway:** preserve replay URL citations ([da88830](https://github.com/icoretech/codex-pooler/commit/da8883081266cbd3e4fa98ff113c32908a9384a5))
* **test:** keep EPMD alive across test partitions ([197aafa](https://github.com/icoretech/codex-pooler/commit/197aafa9e2d5f132598a95408c12e6ab596a130a))

## [0.6.2](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.6.1...codex-pooler-v0.6.2) (2026-08-14)


### Bug Fixes

* **accounting:** preserve reported reasoning and zero cache reads ([54027b5](https://github.com/icoretech/codex-pooler/commit/54027b525d777e5c8e19839b12d01ecee53db563))
* **admin:** align upstream token leaderboard columns ([d1e1ce4](https://github.com/icoretech/codex-pooler/commit/d1e1ce4606fae405e01c010580048296b6dc507c))
* **admin:** clarify traffic series and separate chart colors ([8cd613b](https://github.com/icoretech/codex-pooler/commit/8cd613b717e07f19ec120ea12fc39351b9275c39))
* **admin:** rebalance upstream cards across tablet widths ([28f8eeb](https://github.com/icoretech/codex-pooler/commit/28f8eeb1fd686f3ab4a4c9cb8cf8ebdb1cf06389))
* **admin:** stop sidebar labels resizing during navigation ([1f1ecd9](https://github.com/icoretech/codex-pooler/commit/1f1ecd9118c7e0efdfb602203f38d1e495470933))
* **gateway:** accept standalone CR SSE framing ([8533b96](https://github.com/icoretech/codex-pooler/commit/8533b9624d378b450fe3c8a068ccd39ee033efbc))
* **gateway:** forward compaction triggers through Responses ([35ec313](https://github.com/icoretech/codex-pooler/commit/35ec313187682bc41f1e186ac7417a389474b0b2))
* **gateway:** observe standalone CR rate limits ([f5b771d](https://github.com/icoretech/codex-pooler/commit/f5b771dc143a7f6481e1f367836888d60132725b))
* **gateway:** retain full SSE state for quota events ([888c8e7](https://github.com/icoretech/codex-pooler/commit/888c8e71daba601b4306fa0ace1ca8aaca973c32))
* **settings:** exclude writer cache from invalidations ([dcf2702](https://github.com/icoretech/codex-pooler/commit/dcf27027ccf8e54c78cde31d1b7439701014de5a))
* **stats:** cover rolling windows with bounded projections ([ace36cc](https://github.com/icoretech/codex-pooler/commit/ace36cc4dd4ba300abc632b6bb029b76541b6b91))
* **test:** isolate bundle import job assertions ([d10a869](https://github.com/icoretech/codex-pooler/commit/d10a869581f5fb725530970d4bc1a616b609676d))
* **test:** synchronize websocket concurrency checks ([a820bd6](https://github.com/icoretech/codex-pooler/commit/a820bd6f9e43ec290d9b1e2484ebad4a823d25e3))

## [0.6.1](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.6.0...codex-pooler-v0.6.1) (2026-08-13)


### Features

* **admin:** finish the OAuth link dialog on a screen of its own ([73ed2cc](https://github.com/icoretech/codex-pooler/commit/73ed2cc42cce376c85d90ce30dbcf4e53202d249))
* **admin:** fold the device expiry into the sentence, as a live countdown ([4891c95](https://github.com/icoretech/codex-pooler/commit/4891c95ece788683d20665f8c0bf9ddfb3453d72))
* **admin:** open Pool workflows in upstreams ([79f5fa5](https://github.com/icoretech/codex-pooler/commit/79f5fa5bd8665b5156af9bcbeb7d57cb6f51e217))
* **admin:** open the collapsed sidebar rail on hover and focus ([c62e63e](https://github.com/icoretech/codex-pooler/commit/c62e63e5aa723b1432bdda59d3a6ab15fc572765))
* **admin:** say when the device code expires ([c5687bf](https://github.com/icoretech/codex-pooler/commit/c5687bf1f8d940ccd3d987ccd97d4d74c65fbd89))
* **dev:** put all 20 admin dialogs in the gallery, and fix what that exposed ([4032c6a](https://github.com/icoretech/codex-pooler/commit/4032c6aaaa7a9632fe106d12bab56badfa823e69))
* **dev:** review the OAuth dialog in every state, and align the device route ([aafd3d2](https://github.com/icoretech/codex-pooler/commit/aafd3d2fd67eb753f452bcdf27e0911fc4ad28dc))
* **openai:** support Chat custom tools ([6e27c31](https://github.com/icoretech/codex-pooler/commit/6e27c319087322c71e82059b99e80335a84fd6ce))


### Bug Fixes

* **admin:** clarify browser oauth handoff ([6b24021](https://github.com/icoretech/codex-pooler/commit/6b24021466d110b3827e3c3f6d2c6aaf771fb040))
* **admin:** drop the browser flow's pending line ([7002cd8](https://github.com/icoretech/codex-pooler/commit/7002cd881b4a60ae2e4fa802e1fa82bc7f0ae7b1))
* **admin:** emphasise the value a confirmation field asks you to type ([0ac5d40](https://github.com/icoretech/codex-pooler/commit/0ac5d401956ebdb57262c832b665c7692b62eb2f))
* **admin:** finish the destructive-dialog vocabulary ([9fb2f5c](https://github.com/icoretech/codex-pooler/commit/9fb2f5c70bcae00ef55c150cdf7cbd3823130554))
* **admin:** let a body-less confirm stop drawing an empty body ([cfd3fb6](https://github.com/icoretech/codex-pooler/commit/cfd3fb6dc3431874a8e97a151f557bfbe3d4f068))
* **admin:** let the device status say a poll is running, and sit with the code ([5609f3b](https://github.com/icoretech/codex-pooler/commit/5609f3b50b0c1a3e252e01a4dfbdb8eda5e89fed))
* **admin:** make every dialog usable with a thumb ([6ce544a](https://github.com/icoretech/codex-pooler/commit/6ce544a39194dcb1a756dc0f2c18267de088c10e))
* **admin:** name the live upstream account in traffic distribution ([d347cfd](https://github.com/icoretech/codex-pooler/commit/d347cfd3352fa90fbbc9edefe3447bd028ce2fbe))
* **admin:** name the Pool the wizard is editing ([f08a579](https://github.com/icoretech/codex-pooler/commit/f08a57956cf1f91c23d8526dd623182f9529a644))
* **admin:** narrow the dialog touch floor, and fit the model list on a phone ([b153b05](https://github.com/icoretech/codex-pooler/commit/b153b053a1d1bd91f562602c8f5c3fd135b5441c))
* **admin:** one confirm mechanism across all seven delete dialogs ([f5c6ac0](https://github.com/icoretech/codex-pooler/commit/f5c6ac0ed37f2cda0040ade5329f4d9ae54a35ec))
* **admin:** say each thing once, and line the dialogs up ([3919ede](https://github.com/icoretech/codex-pooler/commit/3919ede139bce2e111bfdbca9b23deab20965a2e))
* **admin:** settle the OAuth dialog's type, sizing and pending line ([1f75db3](https://github.com/icoretech/codex-pooler/commit/1f75db3289e10b9bf45aa14c0b3c81203eeb38c4))
* **admin:** stop two delete dialogs wearing a red shell nobody else wears ([99b8fb7](https://github.com/icoretech/codex-pooler/commit/99b8fb7499e9166d374538bd2b9de354778bb0ef))
* **admin:** use a real spinner for the device wait, and group it with the code ([ef8c0b1](https://github.com/icoretech/codex-pooler/commit/ef8c0b172ddcbd63e4dd3f5893b7aff4f315763c))
* **auth:** preserve pending device authorization flows ([6748fde](https://github.com/icoretech/codex-pooler/commit/6748fde709d0e05f8bbc2389e7968ed7a5098f74))
* **dev:** lift the showcase state switcher above the dialog ([b34b66c](https://github.com/icoretech/codex-pooler/commit/b34b66cef55061cc87bea49488c81558ef39fc16))
* **dev:** make the showcase OAuth dialog usable, not just visible ([ef7c805](https://github.com/icoretech/codex-pooler/commit/ef7c80529603fca30f140938ef8c28bf4d9ff084))
* **gateway:** define native Codex response control foundations ([c4d22f3](https://github.com/icoretech/codex-pooler/commit/c4d22f3c8f767c97ff432dd54127232fda54029a))
* **gateway:** relay native Codex response controls ([0750ec4](https://github.com/icoretech/codex-pooler/commit/0750ec4cbb9b2b9ab5cc2bdb3e16636303c326cb))
* **onboarding:** make invite device state authoritative ([899368e](https://github.com/icoretech/codex-pooler/commit/899368e1326b31ab26f653a293c7120a457e5794))
* **onboarding:** refresh and rebalance hosted invites ([d188d29](https://github.com/icoretech/codex-pooler/commit/d188d297db29220d29c0bd7c732d43d687b89def))
* **runtime:** preserve firewall revocation across settings recreation ([99a1e01](https://github.com/icoretech/codex-pooler/commit/99a1e01b2bff1bf0662f9d78e05bc2b553c887e0))
* **websocket:** preserve native response metadata semantics ([651ec84](https://github.com/icoretech/codex-pooler/commit/651ec847ac267e226d1deb4bad78cb95ed3173d5))

## [0.6.0](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.5.18...codex-pooler-v0.6.0) (2026-08-12)


### Features

* **admin:** expose metrics authentication state ([7ada8d5](https://github.com/icoretech/codex-pooler/commit/7ada8d5dacbd0fcec76e72ed09ed7957f2b76598))
* **admin:** show runtime firewall session state ([de3bd07](https://github.com/icoretech/codex-pooler/commit/de3bd0767862a1708c0378b1e4dec934b967a5f3))
* **dev:** capture Task14 websocket product stages ([90e3f49](https://github.com/icoretech/codex-pooler/commit/90e3f49e57d07df3804387da4f07a468b4cb1d53))
* **dev:** secure upstream account bundle transfer ([7645670](https://github.com/icoretech/codex-pooler/commit/7645670d2ebf221ae9ec7b93dd5f605d4e386903))
* **gateway:** gate routing hints on credential provenance ([7af05b3](https://github.com/icoretech/codex-pooler/commit/7af05b3ed3f0844a669cb73d9cc0a2e5b05adb67))
* **ingress:** add explicit forwarded client policy ([1652d3a](https://github.com/icoretech/codex-pooler/commit/1652d3a43a44f4fef3893f8d25c9998446cba34a))
* **ingress:** expose firewall denial telemetry ([6f3db40](https://github.com/icoretech/codex-pooler/commit/6f3db400b80cd3566a022e42f6339eae8731b689))
* **mcp:** support the 2026-07-28 protocol ([cacc0cd](https://github.com/icoretech/codex-pooler/commit/cacc0cdcd05a3ffbd2d3cf0a41d0115d0c4441c1))
* **observability:** expose reset confirmation phases ([5645e43](https://github.com/icoretech/codex-pooler/commit/5645e432f2e6c2cbe922c6512b2fd0a2e18a1132))
* **security:** retain bounded ingress peer provenance ([0b482bf](https://github.com/icoretech/codex-pooler/commit/0b482bfb25e2c8582278b921dc261347ff9c011f))


### Bug Fixes

* **admin:** align serving-mode permissions ([514d001](https://github.com/icoretech/codex-pooler/commit/514d0014b51e7a4dab35bb4f614fd43d8413592f))
* **admin:** clarify runtime firewall route scope ([0e6962f](https://github.com/icoretech/codex-pooler/commit/0e6962fe39c10c30c0f410647e2007ae18694e84))
* **admin:** complete firewall session state coverage ([fe7ea2d](https://github.com/icoretech/codex-pooler/commit/fe7ea2d42ef85b684b4ad43fe019ba4794577a76))
* **admin:** correct quota and saved reset meter states ([c263d90](https://github.com/icoretech/codex-pooler/commit/c263d90629ba406cc4b2462ab6ba9e3c3f9ac616))
* **admin:** describe bridge ring rendezvous ordering ([c8dbe44](https://github.com/icoretech/codex-pooler/commit/c8dbe4411b5799a2df9eff47daf85b6a8ddf67a5))
* **admin:** explain applied reset quota confirmation ([d549738](https://github.com/icoretech/codex-pooler/commit/d549738aa712a86e0560718785de39d71d18b616))
* **admin:** keep provider quota authoritative across reset precision ([c6085c2](https://github.com/icoretech/codex-pooler/commit/c6085c264fe74ae3ca5bee28063860164fefe12f))
* **admin:** render unknown quota meters as static ([da65a05](https://github.com/icoretech/codex-pooler/commit/da65a050461a7ad1bd5c196a588ae1a68b64be3e))
* **admin:** show request serving-mode metadata ([5298761](https://github.com/icoretech/codex-pooler/commit/52987615897bd81d0092ccd2e945dd80e8347d5f))
* **api:** validate Codex Responses continuations ([3bf3a3e](https://github.com/icoretech/codex-pooler/commit/3bf3a3e98432fdf16b5ba51ea8a696cdb7c9f167))
* **catalog:** avoid duplicate-key errors on pricing reimports ([1913451](https://github.com/icoretech/codex-pooler/commit/1913451e439570f60d9feeb0c0674db28267c552))
* **deps:** update dependency @astrojs/starlight to v0.41.7 ([#265](https://github.com/icoretech/codex-pooler/issues/265)) ([c1bea14](https://github.com/icoretech/codex-pooler/commit/c1bea14bad647f33ae79888cefa0287221696a6e))
* **deps:** update dependency apexcharts to v6.7.1 ([#274](https://github.com/icoretech/codex-pooler/issues/274)) ([246faf8](https://github.com/icoretech/codex-pooler/commit/246faf878616201cc424aef4866b63146c947123))
* **deps:** update dependency apexcharts to v6.8.0 ([#275](https://github.com/icoretech/codex-pooler/issues/275)) ([0995ed1](https://github.com/icoretech/codex-pooler/commit/0995ed1fdea1e68f089171dfa07ada3f0a2b1531))
* **dev:** preserve lifecycle command PATH ([32d8002](https://github.com/icoretech/codex-pooler/commit/32d8002849787204bd75e07059c7680a49173b6c))
* **dev:** recover stale local server receipts ([8ea0df0](https://github.com/icoretech/codex-pooler/commit/8ea0df0bd24e97739fd940984913a733070c0681))
* **dev:** recover verified legacy server state ([aea8f49](https://github.com/icoretech/codex-pooler/commit/aea8f499cdce9271c37397d110d676daaf313bf8))
* **dev:** report Task14 observer event drops ([ad1bd39](https://github.com/icoretech/codex-pooler/commit/ad1bd39121abdb5dcbd60ac7f1438803f6d623b3))
* **dev:** resolve impeccable live helper from its handshake file ([439acec](https://github.com/icoretech/codex-pooler/commit/439acec3b8eb3a3dc6da1acd6fc4e3843ec92d81))
* **dev:** retain Task14 observations without client request ids ([92ed765](https://github.com/icoretech/codex-pooler/commit/92ed7650aea4248fd2ad9f3cca57689f273f32ce))
* **dev:** retain Task14 response correlations per request ([23dc9f2](https://github.com/icoretech/codex-pooler/commit/23dc9f29d102a7225bd44d813c9132ee2a66ae0f))
* **dev:** scope impeccable live constants to the dev-features guard ([ef8553f](https://github.com/icoretech/codex-pooler/commit/ef8553f3cf63d7e86838b702a304a4b8da624bfa))
* **dev:** size the Task 14 product observer for a real round ([e7e457a](https://github.com/icoretech/codex-pooler/commit/e7e457a05c67d404dbda058d7d6ca65e4a5a9017))
* **dev:** use the bootstrap owner for bundle imports ([0aa55b9](https://github.com/icoretech/codex-pooler/commit/0aa55b9b088f5b9aef4975258ecf3d8ebd80c9c1))
* **docs:** enforce ingress boundary contract ([3bbea63](https://github.com/icoretech/codex-pooler/commit/3bbea635003ba6d860cb7073c203051f9d810d2f))
* **gateway:** align Codex compaction forwarding ([0873589](https://github.com/icoretech/codex-pooler/commit/0873589ef36fd0d72d81dc8c86d7cf01caa62462))
* **gateway:** cancel abandoned websocket work across topologies ([4cf4b18](https://github.com/icoretech/codex-pooler/commit/4cf4b182a083234535d42db69686ad0159809e96))
* **gateway:** close abandoned upstream websocket requests ([4988adb](https://github.com/icoretech/codex-pooler/commit/4988adbb95a6186e04274cc076628edcaf03f82d))
* **gateway:** define Codex serving-mode selection ([b2fab3e](https://github.com/icoretech/codex-pooler/commit/b2fab3e995adf916c894dc5f9c52491282e893f0))
* **gateway:** emit Codex overload wire errors ([3eceded](https://github.com/icoretech/codex-pooler/commit/3eceded291ccc73f39f2f33aa3099d1419407951))
* **gateway:** enforce image generation policy in dispatch ([51ad37a](https://github.com/icoretech/codex-pooler/commit/51ad37a165e890575f4da2f2e544ec2bc58545e9))
* **gateway:** preserve native Lite request content ([d433507](https://github.com/icoretech/codex-pooler/commit/d4335079632571ad3224f1a8adbbf6b2b1047698))
* **gateway:** preserve reasoning replay continuations ([3454f89](https://github.com/icoretech/codex-pooler/commit/3454f89a583dcb96fe1200aae4879e1055898094))
* **gateway:** preserve schema properties during marker cleanup ([b168f22](https://github.com/icoretech/codex-pooler/commit/b168f220bcf02a567a24dfe2cf3af026726a5afb))
* **gateway:** preserve schema-bound tool outputs ([190a430](https://github.com/icoretech/codex-pooler/commit/190a430a1f2fa474e7d8613c1b9f3c755b4f2ff8))
* **gateway:** preserve trusted credential provenance ([75c8031](https://github.com/icoretech/codex-pooler/commit/75c803153d949cd7aa73bc762c78c5d3edacff94))
* **gateway:** retain valid encrypted reasoning ([fdf553c](https://github.com/icoretech/codex-pooler/commit/fdf553c808a07be6522cf3bfd3aef44316655d3a))
* **gateway:** snapshot serving mode for image retries ([5f56721](https://github.com/icoretech/codex-pooler/commit/5f56721f4a8a55098c067f6c1adbf8bc9b2406bf))
* **gateway:** stagger websocket owner lease renewals ([c9bd890](https://github.com/icoretech/codex-pooler/commit/c9bd890884ad5375af35248d66fb86d26dc75d08))
* **ingress:** add canonical runtime path classification ([0d29c8d](https://github.com/icoretech/codex-pooler/commit/0d29c8dbf9494528510f142b962651f3cef99b17))
* **ingress:** bound forwarded client resolution ([28d9391](https://github.com/icoretech/codex-pooler/commit/28d9391242c9025eb42bf869359494154cf60e1b))
* **ingress:** enforce configured forwarded client source ([0b68691](https://github.com/icoretech/codex-pooler/commit/0b6869149a6618609fa5a2215a2f53ac768519ab))
* **ingress:** enforce decoded runtime path boundaries ([2487c2a](https://github.com/icoretech/codex-pooler/commit/2487c2af0a870f08d0d172a307d4fb5f9bcc2c07))
* **ingress:** enforce strict canonical IP rules ([f68ae51](https://github.com/icoretech/codex-pooler/commit/f68ae5196de49d94b1c8c36d28571571a44f994f))
* **ingress:** fail closed on unavailable settings ([16ce194](https://github.com/icoretech/codex-pooler/commit/16ce1947ffa7e7fe475d04803e419b05223dca7b))
* **ingress:** reuse forwarded client resolution ([b3d3311](https://github.com/icoretech/codex-pooler/commit/b3d33110c7d3a9eeeadb729500b3c9f8625b9d1c))
* **mcp:** align unsupported protocol error messages ([bb67216](https://github.com/icoretech/codex-pooler/commit/bb67216fd2e78f84213f2bcc0c8ed6b7edd44f4b))
* **mcp:** suppress non-remainder quota balances ([2e00690](https://github.com/icoretech/codex-pooler/commit/2e006908ab9d16695f34520fd2430f0a238652b1))
* **monitoring:** scope firewall denial dashboard ([3b8dbc7](https://github.com/icoretech/codex-pooler/commit/3b8dbc73ec09ef640a63155dfd3753968851ff04))
* **openai:** adapt explicit prompt cache controls ([7ae45e7](https://github.com/icoretech/codex-pooler/commit/7ae45e7c86ea4479c684f49abc6b652acf844832))
* preserve quota and credit state convergence ([5966d7d](https://github.com/icoretech/codex-pooler/commit/5966d7ddd8eb88ec76544b9391d9ca0f2a20288e))
* **quota:** derive freshness at read time ([79eb794](https://github.com/icoretech/codex-pooler/commit/79eb7944c63d64d06bd0b2d8ddd4f0bd9f84187d))
* **quota:** normalize freshness evidence aliases ([799c3da](https://github.com/icoretech/codex-pooler/commit/799c3da91c7107f39884412e4c9e6b096f3a131a))
* **quota:** preserve explicit account reset provenance ([d54383f](https://github.com/icoretech/codex-pooler/commit/d54383f50bea666591e15cab8aa4ccb42beb330c))
* **responses:** accept custom tools inside namespaces ([245e280](https://github.com/icoretech/codex-pooler/commit/245e28031b545edbb8e06574f93a8ee5c518dbd8))
* **responses:** clarify namespace tool validation error ([77cb8fd](https://github.com/icoretech/codex-pooler/commit/77cb8fd99af5c6487b87ee418b4eb59e4d782334))
* **responses:** preserve reasoning replay content ([7e44dcc](https://github.com/icoretech/codex-pooler/commit/7e44dcc211db1e72bd4037c0eccfc7620be5c3d2))
* **routing:** bind circuit completions to admitted probes ([61006b1](https://github.com/icoretech/codex-pooler/commit/61006b189f99d21cd0f4071acb131e3af0c39898))
* **routing:** record attempt-owned circuit recovery outcomes ([791d844](https://github.com/icoretech/codex-pooler/commit/791d8446478b10d1b3faab7fc6b6db8019e9d922))
* **routing:** score reported-percent exhaustion as empty ([844b737](https://github.com/icoretech/codex-pooler/commit/844b737cadc0b98b4325a769d9641d2ca8beefd3))
* **saved-resets:** close post-consume convergence handoff ([1bc9f83](https://github.com/icoretech/codex-pooler/commit/1bc9f83f696ff3cfdc7202a8a37135f3a4697f16))
* **saved-resets:** defer burns for recoverable circuit siblings ([21bf4b3](https://github.com/icoretech/codex-pooler/commit/21bf4b33bc77c22f2d00f759d44ef3b04b464374))
* **security:** bind local browser trust to the immediate peer ([e9580ba](https://github.com/icoretech/codex-pooler/commit/e9580ba1ecbf9c2fff5d8c94061b114fe4781555))
* **security:** enforce ingress firewall for pruned runtime routes ([67fbefd](https://github.com/icoretech/codex-pooler/commit/67fbefd4f937850d91094891201508b4d6a5a038))
* **security:** reject malformed immediate peer addresses ([2da890e](https://github.com/icoretech/codex-pooler/commit/2da890e9b935d5d3f67a37fb6ef28793500b8d53))
* **security:** validate preserved peer addresses with OTP ([e0f3c02](https://github.com/icoretech/codex-pooler/commit/e0f3c025998356a00d26178aca15943088b9e47e))
* **settings:** make instance cache self-healing ([d16895d](https://github.com/icoretech/codex-pooler/commit/d16895de1fb4b70072f5dd4bac474c9bbd5e18f1))
* **settings:** remove unsupported database setting env aliases ([2ba2287](https://github.com/icoretech/codex-pooler/commit/2ba22874800583212b6287dfe879ff5b9705ef26))
* **test:** isolate database state and expected logs ([64c5f42](https://github.com/icoretech/codex-pooler/commit/64c5f425426e2ea68291b83653e78cb1805eb56f))
* **upstreams:** parse Cloudflare cookie dates without httpd ([e69a78e](https://github.com/icoretech/codex-pooler/commit/e69a78e04e441f723ded8424470232b0529e3208))
* **usage:** omit synthetic credits metadata ([d8c1579](https://github.com/icoretech/codex-pooler/commit/d8c15799626634a5bd02197f160be63680715073))
* **usage:** require all emitted quota windows to allow ([7552c20](https://github.com/icoretech/codex-pooler/commit/7552c20e60851756726599ee4f37f137095e24b7))
* **v1:** centralize pool compatibility authorization ([baed23c](https://github.com/icoretech/codex-pooler/commit/baed23c84e3f0677582060ca756419432bceb7d2))
* **websocket:** revoke sockets after firewall updates ([578b90a](https://github.com/icoretech/codex-pooler/commit/578b90a40b04d626195623b49e4e466f6e930162))


### Performance Improvements

* **gateway:** compile test settings overrides out of production ([10fba6e](https://github.com/icoretech/codex-pooler/commit/10fba6e1274bdd10196cf47e027278db150e3202))


### Miscellaneous Chores

* release 0.6.0 ([e719fbe](https://github.com/icoretech/codex-pooler/commit/e719fbeb9b3da114eefcfa965c4cd44e6e01413d))

## [0.5.18](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.5.17...codex-pooler-v0.5.18) (2026-08-05)


### Bug Fixes

* **deps:** update dependency daisyui to v5.7.16 ([#262](https://github.com/icoretech/codex-pooler/issues/262)) ([02403d8](https://github.com/icoretech/codex-pooler/commit/02403d8df88c742cc835836b7a1868274f87152a))
* **gateway:** preserve encrypted agent v2 handoffs ([e352aae](https://github.com/icoretech/codex-pooler/commit/e352aaea60b54be71488662e2a059530f7a4a9ca))
* **routing:** drain assignment locks before deadlock retries ([07113b2](https://github.com/icoretech/codex-pooler/commit/07113b2b267d9ae6aca8ddbc3dfea5458f7c37bc))

## [0.5.17](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.5.16...codex-pooler-v0.5.17) (2026-08-05)


### Features

* **admin:** bring the operator dialogs onto the house selection idioms ([f4285af](https://github.com/icoretech/codex-pooler/commit/f4285af8d22432bd5e3b4f9c8506789d461ab373))
* **admin:** explain discovered models in context ([3747e16](https://github.com/icoretech/codex-pooler/commit/3747e164d7b624343d56682c4c16bc607c6bb080))
* **admin:** finish the selection-card contract on the API-key wizard ([f8cd62b](https://github.com/icoretech/codex-pooler/commit/f8cd62bbad73001438d4fca086341244918e7217))
* **admin:** let the operator pause auto-refresh ([26c4926](https://github.com/icoretech/codex-pooler/commit/26c492640e3f644e1b7de01973d4072820f8d519))
* **admin:** make single-choice policy cards radio-less selection cards ([b0a03aa](https://github.com/icoretech/codex-pooler/commit/b0a03aa0555b447a9f2582079244d06927630a15))
* **admin:** open the Observatory exit by holding, not clicking ([f186e87](https://github.com/icoretech/codex-pooler/commit/f186e874b5f03d40b73ba3594d49ce6fba931e16))
* **admin:** rebuild the operators page as profile cards ([2c1372e](https://github.com/icoretech/codex-pooler/commit/2c1372ea079ea0a974bd094beab2d9847fe1e3a5))
* **admin:** retell the audit trail as a prose ledger ([0176e51](https://github.com/icoretech/codex-pooler/commit/0176e51605757d6946e31bc627ba7ed1b7f3e485))
* **admin:** tell what an assignment burns, not whether it is Eligible ([fade06c](https://github.com/icoretech/codex-pooler/commit/fade06cf97d1ce751447be03a50c87f1d507ffaf))
* **audit-logs:** page the audit list on the request-log contract ([09f5eef](https://github.com/icoretech/codex-pooler/commit/09f5eef4ab21737a9baeb494c0420967883ef273))


### Bug Fixes

* **admin:** distinguish async loading from empty states ([fc128cf](https://github.com/icoretech/codex-pooler/commit/fc128cfd97b9d388d696b40c399d8c1b5968d053))
* **admin:** drop the hairline above the saved-reset numeric fields ([2920208](https://github.com/icoretech/codex-pooler/commit/292020898a0abddb5c5ca51fd9b4f4802d53a757))
* **admin:** drop the resting-card shadow from the settings family ([cb818c1](https://github.com/icoretech/codex-pooler/commit/cb818c1e24e2f0a20b200a2c84f9c723c107cdda))
* **admin:** give the API key rows their width back on a phone ([b01641e](https://github.com/icoretech/codex-pooler/commit/b01641edf879b8058be3473b4b0789f54febf3e4))
* **admin:** head the operator dialog groups with the house kicker ([d955beb](https://github.com/icoretech/codex-pooler/commit/d955bebc944a180d47abd9b04e12c737b1ae1830))
* **admin:** keep operator card heights independent, like upstreams ([f440234](https://github.com/icoretech/codex-pooler/commit/f4402340a71552a0cc02fb3e52d91114cf608a6a))
* **admin:** keep wizard step tabs to one row on tablets ([6ea7288](https://github.com/icoretech/codex-pooler/commit/6ea7288cf2bb502d9a2c87a21baa7d2d3ec0823e))
* **admin:** let a Pool name have the room its card header has ([c6e4557](https://github.com/icoretech/codex-pooler/commit/c6e4557163454c6f8782d1fa39576b39041b20a2))
* **admin:** make gated saved-reset tunables read-only, not just dim ([0de29fd](https://github.com/icoretech/codex-pooler/commit/0de29fdd5647f75267ba3c5f3b69b5800602c950))
* **admin:** preserve cockpit metrics across async reloads ([6634a60](https://github.com/icoretech/codex-pooler/commit/6634a60006d4d6e1570787a4485db84f35edcd55))
* **admin:** refresh quiet pool traffic on a fallback tick ([46bd71c](https://github.com/icoretech/codex-pooler/commit/46bd71cd1e4c79e4c374ae763a3eb2ee6001147e))
* **admin:** stop a resume from forgetting the reload a dialog deferred ([e371d88](https://github.com/icoretech/codex-pooler/commit/e371d881e537c74142864bb5336e2d1e8795d566))
* **admin:** stop an unpinned page number from hiding the rows behind it ([cd13e42](https://github.com/icoretech/codex-pooler/commit/cd13e4275c509601c1366abb328c8f88b0d52557))
* **admin:** stop the pause from leaving admin pages deaf to events ([12723c6](https://github.com/icoretech/codex-pooler/commit/12723c6cdd0df1d885871830c17b52f80df4685f))
* **request-logs:** pin the paged window to a row, not to a clock ([0c43217](https://github.com/icoretech/codex-pooler/commit/0c4321715ee8d72beba639187f65abf492b87813))
* **request-logs:** repair the tablet band and page a live list ([ca817ac](https://github.com/icoretech/codex-pooler/commit/ca817acb8bafa661cce85997661cd2034d24411c))
* **stats:** give the Tokens KPI one description line like its siblings ([6aae82f](https://github.com/icoretech/codex-pooler/commit/6aae82fb7545ca5b92a6262f87bf6cecdc4507d8))


### Performance Improvements

* **admin:** aggregate cockpit request metrics asynchronously ([cd174f4](https://github.com/icoretech/codex-pooler/commit/cd174f4348ef89a77dd2567a121ae25a7fe4512e))
* **admin:** batch API key page reads ([2b9d743](https://github.com/icoretech/codex-pooler/commit/2b9d743a75a09183036f714920dc0f487ddb2b14))
* **admin:** build stats dashboards off the LiveView process ([6e99f0a](https://github.com/icoretech/codex-pooler/commit/6e99f0ad733f4e57ef8148d499e184aef2bbda4b))
* **admin:** load request logs outside the LiveView process ([203a3a0](https://github.com/icoretech/codex-pooler/commit/203a3a054aba9f685625e432d4db13ae86c96210))
* **admin:** move upstream event reloads off the LiveView process ([5c25567](https://github.com/icoretech/codex-pooler/commit/5c25567cd6e3aa3d4da56438ed2e23f678d88626))

## [0.5.16](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.5.15...codex-pooler-v0.5.16) (2026-08-05)


### Bug Fixes

* **deps:** update DaisyUI to v5.7.15 ([1f7c008](https://github.com/icoretech/codex-pooler/commit/1f7c0080c7d365a51679b89cb257c56c540fce22))
* **responses:** accept nullable function output metadata ([821498b](https://github.com/icoretech/codex-pooler/commit/821498b07a4a0d5d496c9bce7e2f87f9d86118a2))

## [0.5.15](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.5.14...codex-pooler-v0.5.15) (2026-08-05)


### Bug Fixes

* **admin:** label applied reblock as converging ([24eeca2](https://github.com/icoretech/codex-pooler/commit/24eeca26b6517fd02484b7c3ce4d0b1b981620b3))
* **jobs:** enqueue stale reset recovery once ([462ff61](https://github.com/icoretech/codex-pooler/commit/462ff61576eb45994d522e1c3dd9b19604877f95))
* **responses:** accept verified compaction replay metadata ([265c306](https://github.com/icoretech/codex-pooler/commit/265c306574682c13bcd4e917695bab1c0318e8d7))
* **saved-resets:** complete guarded reset recovery ([1717779](https://github.com/icoretech/codex-pooler/commit/17177792d664fd41026280671e8282b29848755f))
* **saved-resets:** converge from canonical quota evidence ([4160662](https://github.com/icoretech/codex-pooler/commit/4160662f9123991dc217a7a51d9a59158e0e0c13))
* **saved-resets:** define cohort sibling fence lifecycle ([5ddc2e3](https://github.com/icoretech/codex-pooler/commit/5ddc2e39b4c717a11b72bf7b2f104a050fdaf9de))
* **saved-resets:** enforce sibling auto-redeem barrier ([e4ee118](https://github.com/icoretech/codex-pooler/commit/e4ee11811167418a74238701ffd5e5078cbd4c61))
* **saved-resets:** exclude websocket pins from the capacity-veto bypass ([5864d8c](https://github.com/icoretech/codex-pooler/commit/5864d8c4395eef8ce14e70435fcfe1005b03b701))
* **saved-resets:** fence recovery finalizers and replay cutoff ([5743a8d](https://github.com/icoretech/codex-pooler/commit/5743a8dc7ab4ca61215bcdeb6c3d4a95b7c79aeb))
* **saved-resets:** fence zero-dispatch claims and stale observers ([9985cbf](https://github.com/icoretech/codex-pooler/commit/9985cbfe1298001510a592d900ce02691eebb1f4))
* **saved-resets:** gate threshold burns on hard continuity ([1193803](https://github.com/icoretech/codex-pooler/commit/119380334291f9e2180dbad4dae764ac428f78c4))
* **saved-resets:** pin exact credit before consume ([eaad8ee](https://github.com/icoretech/codex-pooler/commit/eaad8ee13b5f64b3433e670c577cbe3a2b7612ba))
* **saved-resets:** prove anchors at attach, fold like routing ([c3d43b1](https://github.com/icoretech/codex-pooler/commit/c3d43b1a088bc1d57c0024242b24cad80f189546))
* **saved-resets:** require resolved anchors and fresh schedules ([c101e59](https://github.com/icoretech/codex-pooler/commit/c101e59106f06a50ada56747b538996303b50569))
* **saved-resets:** serialize sibling auto-redeem cohorts ([0e0c21e](https://github.com/icoretech/codex-pooler/commit/0e0c21eafe78a28e0881cfbe341213fa9c59af57))

## [0.5.14](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.5.13...codex-pooler-v0.5.14) (2026-08-04)


### Features

* **admin:** label the ChatGPT Go plan and newer known plan values ([6c1296b](https://github.com/icoretech/codex-pooler/commit/6c1296b281839217d3091a650c612052ace63a48))
* **audio:** add gpt-transcribe request compatibility ([d3c4c7f](https://github.com/icoretech/codex-pooler/commit/d3c4c7fa9b09c970efcf3167375ef1bc1b16939d))
* **routing:** persist canonical partition evidence on successful turns ([785b398](https://github.com/icoretech/codex-pooler/commit/785b39828ed7ef004cc8156df684f638c64d7396))
* **v1:** support executable Responses custom tools ([361f937](https://github.com/icoretech/codex-pooler/commit/361f937daf6fadc8ce3ceaa65b9d9f7c273dd38d))


### Bug Fixes

* **catalog:** anchor partitions on chronological assignment age ([0d9c739](https://github.com/icoretech/codex-pooler/commit/0d9c739ec82c4e4e21c683c10ef413bd3d6045eb))
* **catalog:** stop presentation hints from splitting canonical partitions ([3fe19fb](https://github.com/icoretech/codex-pooler/commit/3fe19fbd7b39ae14f8916110886d0f43d0da1b5e))
* **deps:** update dependency daisyui to v5.7.14 ([#243](https://github.com/icoretech/codex-pooler/issues/243)) ([9321017](https://github.com/icoretech/codex-pooler/commit/932101747e5de64b1d6a5f786172ef6a88c25929))
* **gateway:** normalize visible models before pre-dispatch ([7782c35](https://github.com/icoretech/codex-pooler/commit/7782c35f32703e1bf489ca16423103628b999265))
* **gateway:** preserve compaction replay metadata ([3347288](https://github.com/icoretech/codex-pooler/commit/33472883dc1ffc3c31cafb09ca228af8d06419e5))
* **gateway:** preserve model-scoped canonical capability partitions ([06597a7](https://github.com/icoretech/codex-pooler/commit/06597a7bb8a3e9a2862c413780aff05a2e0de5de))
* **gateway:** preserve null upstream terminal errors on streamed responses ([ff95e50](https://github.com/icoretech/codex-pooler/commit/ff95e5059d1faf7df8962373f022ec7ea28fceb4))
* **responses:** accept web search domain filters ([a0bb47e](https://github.com/icoretech/codex-pooler/commit/a0bb47ec3230d78f6622f33f8f55133c3cd5755d))
* **responses:** reject reserved passthrough metadata ([daf9a65](https://github.com/icoretech/codex-pooler/commit/daf9a658e20c6df4c3afe0a3ac3476e25dd8cbdc))
* **routing:** anchor canonical partitions on a quota-routable partition ([a74251c](https://github.com/icoretech/codex-pooler/commit/a74251cb9dd33bf8c7ba87da9e00b624bf8c0050))
* **routing:** resolve dispatch partition routability from one quota snapshot ([813efab](https://github.com/icoretech/codex-pooler/commit/813efab6878fb675963d2e4ecee8bd807ea1ab1e))
* **routing:** scope partition filtering evidence to the capped surfaces ([c1f5ea4](https://github.com/icoretech/codex-pooler/commit/c1f5ea4fa3a3d04ff53d569904465bde8e1ba9f3))
* **v1:** declare content provenance checks unsupported ([50f5226](https://github.com/icoretech/codex-pooler/commit/50f5226d1aa2bbcc6196e638323eb99bb42b5808))
* **v1:** reject typed tool_choice on Responses-Lite dispatch ([29b077b](https://github.com/icoretech/codex-pooler/commit/29b077b2be4d6eabf1a4bbf8c8fd30dc2c5d4d5a))
* **v1:** repair strict nested schema types ([6008c96](https://github.com/icoretech/codex-pooler/commit/6008c96abbf952bb0d479c6e1783c315601e5433))

## [0.5.13](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.5.12...codex-pooler-v0.5.13) (2026-08-02)


### Features

* **gateway:** compress embedded JSON tool outputs ([992d2a3](https://github.com/icoretech/codex-pooler/commit/992d2a3addea49e26b9fad81d1965f8d3b7d5920))


### Bug Fixes

* **accounting:** avoid unused quota scans and handle rollbacks ([069758d](https://github.com/icoretech/codex-pooler/commit/069758dd27f381461fc5c58ae8a2a68474ca161d))
* **accounting:** precompute api key usage windows ([2e941f0](https://github.com/icoretech/codex-pooler/commit/2e941f0b5e12f3faed72105152fc14ac46eb5402))
* **deps:** update dependency @astrojs/starlight to v0.41.6 ([#238](https://github.com/icoretech/codex-pooler/issues/238)) ([3b7aafd](https://github.com/icoretech/codex-pooler/commit/3b7aafd541763c6a1cc4f015ff8914ac7bf165cc))
* **docs:** sync runtime route rate dashboard ([af830dc](https://github.com/icoretech/codex-pooler/commit/af830dcddc2c4c357db4e590328ca497cbc9a0dd))
* **usage:** ignore unclassified plan labels ([adfaae9](https://github.com/icoretech/codex-pooler/commit/adfaae9274b5dabfbc190a90a996a30edbc569ec))
* **usage:** preserve canonical enterprise automation plan token ([3a50563](https://github.com/icoretech/codex-pooler/commit/3a505631b25504458f1e2420bd7669ae4e07cb2c))

## [0.5.12](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.5.11...codex-pooler-v0.5.12) (2026-08-01)


### Features

* **telemetry:** expose gateway outcome and saturation metrics ([ad8b3ba](https://github.com/icoretech/codex-pooler/commit/ad8b3ba3e8f0be869c9369cd10ee0e46992b22a0))


### Bug Fixes

* **jobs:** preserve per-minute reconciliation cadence ([87bdcc7](https://github.com/icoretech/codex-pooler/commit/87bdcc72f38aa5d3104e39af374a82fb97480da9))
* **quota:** confirm fixed-anchor weekly resets ([222ea29](https://github.com/icoretech/codex-pooler/commit/222ea2902e06101042fde81abebd23fd08b84e90))
* **routing:** keep OpenAI capacity across catalog partitions ([c328494](https://github.com/icoretech/codex-pooler/commit/c32849409fb4e5d34dead1f9dcf2a46938ad7070))
* **test:** supervise fake upstream websocket lifecycle ([1d9702e](https://github.com/icoretech/codex-pooler/commit/1d9702ec7ef0c669db02a6defbbeb956466861b4))
* **upstreams:** align usage probe headers with Codex ([c0ca0d0](https://github.com/icoretech/codex-pooler/commit/c0ca0d04536bdaaae2aec2d7152f54dc613c4f5b))
* **upstreams:** refresh catalog after account lifecycle changes ([495998b](https://github.com/icoretech/codex-pooler/commit/495998b0d73d09dbe57508359f62cdab5e301fc5))

## [0.5.11](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.5.10...codex-pooler-v0.5.11) (2026-08-01)


### Features

* **access:** normalize fast policy tier to priority ([6959244](https://github.com/icoretech/codex-pooler/commit/695924492ba6e670896e28d5e8bca05cc5921ad3))
* **accounting:** price legacy fast tier metadata ([18e6003](https://github.com/icoretech/codex-pooler/commit/18e6003083b85ad1ca0499a47e37cb353b901f2d))
* **catalog:** import fast pricing updates safely ([565b728](https://github.com/icoretech/codex-pooler/commit/565b7284ac597058e9263a900b427e36a2f4d6af))
* **docs:** generate the public dashboard from code ([6185773](https://github.com/icoretech/codex-pooler/commit/6185773fd9901b6e2a8a81994998b9035d070602))
* **gateway:** canonicalize fast service tier requests ([335e469](https://github.com/icoretech/codex-pooler/commit/335e469b754eff1a9ab269a04c972a5a37c7213e))
* **observability:** add bounded response id previews ([1fc72c8](https://github.com/icoretech/codex-pooler/commit/1fc72c84ffc07880f6b252bceb0f1ce1d78a2ceb))
* **openai:** accept fast service tier alias ([3d07b60](https://github.com/icoretech/codex-pooler/commit/3d07b60063805c8ddf93b9a72fad484d9496c2bf))
* **routing:** match equivalent fast and priority tiers ([65907f7](https://github.com/icoretech/codex-pooler/commit/65907f7eff011cc414976ba271133c44ace2a002))


### Bug Fixes

* **access:** reject non-binary service tiers ([c74b941](https://github.com/icoretech/codex-pooler/commit/c74b941dd67e2b4eab767e261aa746e329530dee))
* **accounting:** resolve mixed-case pricing identifiers ([1d4a7ac](https://github.com/icoretech/codex-pooler/commit/1d4a7ac971280e650bf01b241f21efb628a5741b))
* **admin:** align pending relink flow input with its contract ([5615825](https://github.com/icoretech/codex-pooler/commit/5615825ac40ae0798863a5b4dbdddf055c1f8f29))
* **admin:** share fast tier request log display ([43b8dc7](https://github.com/icoretech/codex-pooler/commit/43b8dc7c9f6c1d266f02ac03b167aa2cfb71c59b))
* **catalog:** bound Req adapter errors ([acb81b4](https://github.com/icoretech/codex-pooler/commit/acb81b4b7eedbc79e58b66c7a53cf0ffb8180f68))
* **catalog:** reject incomplete fast pricing aliases ([d87cee0](https://github.com/icoretech/codex-pooler/commit/d87cee08cdd3b6cba13200678020ae8520e6e549))
* **catalog:** require matching pricing semantic keys ([f93b6e5](https://github.com/icoretech/codex-pooler/commit/f93b6e516a8322e40fd17c9a128514949ca40337))
* **catalog:** update admin pricing import fixture ([911e393](https://github.com/icoretech/codex-pooler/commit/911e393be29d05c0d19403e475024bf7785584f3))
* **deps:** update dependency daisyui to v5.7.8 ([#224](https://github.com/icoretech/codex-pooler/issues/224)) ([30f8b65](https://github.com/icoretech/codex-pooler/commit/30f8b650afd9c07c7e63fa00ad11320714a2c978))
* **deps:** update dependency daisyui to v5.7.9 ([#233](https://github.com/icoretech/codex-pooler/issues/233)) ([483d671](https://github.com/icoretech/codex-pooler/commit/483d67113cc912cd1fd4692e0b6b26edcc6aab34))
* **deps:** update Swoosh, Phoenix LiveReload, and Astro ([d1a6a0d](https://github.com/icoretech/codex-pooler/commit/d1a6a0d03173b22ca58776ad62ca98f8ead04676))
* **docs:** remove inactive dashboard controls ([8889890](https://github.com/icoretech/codex-pooler/commit/8889890d74e2de1af3996da3c43a3df68d1feb79))
* **gateway:** contain terminal-only owner replies and restore formatting ([d852123](https://github.com/icoretech/codex-pooler/commit/d852123126d1c4725281763ccced6a9f48462161))
* **gateway:** pin native chunk attribution and drop its dead clause ([c2795ae](https://github.com/icoretech/codex-pooler/commit/c2795ae9f4335249bbd8ee1f9384de0bf6c38fa5))
* **gateway:** preserve non-fast backend service tiers ([66ae666](https://github.com/icoretech/codex-pooler/commit/66ae666975895bbd8add99e524ccde2f8de83cbf))
* **gateway:** settle malformed websocket owner replies ([533da1c](https://github.com/icoretech/codex-pooler/commit/533da1cef4d07b8a2c3bda93f31242f235f4476c))
* **gateway:** validate owner replies against the whole contract ([a7d6d49](https://github.com/icoretech/codex-pooler/commit/a7d6d49d7d71c1c02bdee5a85940661d021b672e))
* **gateway:** validate remote websocket owner replies ([f52e6a1](https://github.com/icoretech/codex-pooler/commit/f52e6a12d64ccb45ced8156babc5d2776e72db03))
* **observability:** correct websocket diagnostic correlator and allowlist anchors ([265c176](https://github.com/icoretech/codex-pooler/commit/265c1764cf9c041f6266259848c5dcc0ffa2c82f))
* **observability:** give both containment boundaries one classifying key ([da3b217](https://github.com/icoretech/codex-pooler/commit/da3b217883183926a048433eaa4558d545093277))
* **observability:** join the containment warning to its turn ([5c8d6ad](https://github.com/icoretech/codex-pooler/commit/5c8d6ada65c26631b2a1e29ae7889cfb6182d9c6))
* **observability:** name the debug preview for the id it actually shows ([18b7f87](https://github.com/icoretech/codex-pooler/commit/18b7f878ca167be7ff7bcc14fd2da4b6af1fb371))
* **observability:** preserve websocket failure diagnostics ([359669f](https://github.com/icoretech/codex-pooler/commit/359669f6179738cdf0da7cc09c39a50ee939ee68))
* **observability:** render sanitized unknown websocket codes ([e5c148b](https://github.com/icoretech/codex-pooler/commit/e5c148b3ebaf035ab92e3f3ef38138ce41a785ff))

## [0.5.10](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.5.9...codex-pooler-v0.5.10) (2026-07-31)


### Features

* **admin:** expose saved reset redemption cause ([f77dd8f](https://github.com/icoretech/codex-pooler/commit/f77dd8fe1c1f8d81a949447f7146749a33009926))


### Bug Fixes

* **accounting:** claim and recover websocket turns atomically ([927bb6f](https://github.com/icoretech/codex-pooler/commit/927bb6f7505b4d6c2f87e6dd7ce27b9335a2d978))
* **catalog:** serve canonical upstream model metadata ([3b659d6](https://github.com/icoretech/codex-pooler/commit/3b659d693990aa30ff486cf59cf5661c5be7cdd2))
* **deps:** update dependency astro to v7.1.5 ([#221](https://github.com/icoretech/codex-pooler/issues/221)) ([72c6b9b](https://github.com/icoretech/codex-pooler/commit/72c6b9bd998ee30bd116109b4cdc3759e462cb55))
* **gateway:** capture and register websocket response identity ([ac2d870](https://github.com/icoretech/codex-pooler/commit/ac2d870e64f2374097636f21cce450a2e756ba75))
* **gateway:** forward reserved namespace tool schemas untouched ([721e2d7](https://github.com/icoretech/codex-pooler/commit/721e2d738ec70d922e30d4fbd622249a85f60662))
* **gateway:** harden compression and decompression boundaries ([a733a51](https://github.com/icoretech/codex-pooler/commit/a733a51784797dbc256cf62977af443220094667))
* **gateway:** make routing and session continuity deterministic ([f4b4736](https://github.com/icoretech/codex-pooler/commit/f4b4736fc7a8f720e1cb2eeeee11b72da57c5b2f))
* **gateway:** make streaming classification chunk-safe ([9b7db20](https://github.com/icoretech/codex-pooler/commit/9b7db209d4cd256c3aef92315c1ca46d462495d5))
* **gateway:** make websocket owner terminal delivery idempotent ([eb71896](https://github.com/icoretech/codex-pooler/commit/eb718962b58c90023e40da4d4b43e0cf2d4e1b76))
* **gateway:** preserve decoded websocket frame context ([ff4d7a6](https://github.com/icoretech/codex-pooler/commit/ff4d7a664c4af4d2c02a1d17da4eea26e9d014ea))
* **gateway:** preserve input and compatibility semantics ([df9223d](https://github.com/icoretech/codex-pooler/commit/df9223d7a39e6754ab5cf09f67142da4af8bddaf))
* **gateway:** preserve terminal websocket response identity ([376e34f](https://github.com/icoretech/codex-pooler/commit/376e34f61b14448eee8c981fd1eb6749da29e1f0))
* **gateway:** preserve websocket owner on alias miss ([5043bd8](https://github.com/icoretech/codex-pooler/commit/5043bd8535915c47539a671534e05bef73a82c71))
* **ingress:** accept settings structs in parser contract ([cf17909](https://github.com/icoretech/codex-pooler/commit/cf17909779c838b1f08385099a68af5bd4641644))
* **instance-settings:** publish a secrets-free distributed cache ([16b81c6](https://github.com/icoretech/codex-pooler/commit/16b81c69348b37113919682dfb5267ef43a0b5fb))
* **runtime:** gate reconciliation and preserve rate-limit events ([58b182d](https://github.com/icoretech/codex-pooler/commit/58b182d18fc4133c7e20294ed3bb754dd6a4caf8))
* **saved-resets:** make scheduled rescue the sole expiry owner ([4e1170a](https://github.com/icoretech/codex-pooler/commit/4e1170abe319daf7130c0b25e725b7abac2c2549))
* **ui:** make relative countdowns timezone-independent ([dd8c111](https://github.com/icoretech/codex-pooler/commit/dd8c111e32d7a62a7c6640b22971a82d0033dba6))


### Performance Improvements

* **transports:** reduce admission and file bridge overhead ([900b55b](https://github.com/icoretech/codex-pooler/commit/900b55b88db11b925afb71e05435bc75be44163c))

## [0.5.9](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.5.8...codex-pooler-v0.5.9) (2026-07-29)


### Features

* **admin:** batch circuit evidence for upstream accounts ([9ce0021](https://github.com/icoretech/codex-pooler/commit/9ce0021860ef26dca58e1c44f8418c56be9c8e20))
* **admin:** carry circuit visibility into the upstream cockpit ([e052e5d](https://github.com/icoretech/codex-pooler/commit/e052e5df45add33b289562761e2839f2cef2ac6b))
* **admin:** project upstream circuit readiness ([8b42c53](https://github.com/icoretech/codex-pooler/commit/8b42c53bebd9d5dea77557f40b84a72942c8a994))
* **admin:** show the circuit gate on route paths ([f85fb82](https://github.com/icoretech/codex-pooler/commit/f85fb8209fb5b54193e4b95572b7cc8892b23e5b))
* **admin:** surface circuit evidence in account verdicts ([a4f6d92](https://github.com/icoretech/codex-pooler/commit/a4f6d920c0b7af50614927a39c235e055d8ca9a7))
* **alerts:** count circuit-blocked assignments as unusable ([d7bd593](https://github.com/icoretech/codex-pooler/commit/d7bd59359e1225dda9b8083dc301b3f414247ad7))
* **alerts:** scope alert rules to a route class ([71ce0f8](https://github.com/icoretech/codex-pooler/commit/71ce0f8344de4d3b755546bc8621d1053f14c5ba))
* **gateway:** emit routing circuit transition telemetry ([f8e9d8b](https://github.com/icoretech/codex-pooler/commit/f8e9d8bec4f30d1cf71bb14c71605d2c0759a434))
* **saved-resets:** defer scheduled expiry rescue to burn conditions ([e031d11](https://github.com/icoretech/codex-pooler/commit/e031d11fe0387820e0e92c6beceacf8375e3c6f8))
* **saved-resets:** record scheduled expiry decision metadata ([fda590d](https://github.com/icoretech/codex-pooler/commit/fda590df8512078ad6488779de266427baf3af81))


### Bug Fixes

* **admin:** bound stale open circuit recovery ([7ab841e](https://github.com/icoretech/codex-pooler/commit/7ab841e50625493b3c7a42eab46b1ec62f676232))
* **admin:** eliminate assignment gate overflow ([50030d8](https://github.com/icoretech/codex-pooler/commit/50030d871e41e3d72581ec7b4f24a35a4ff5335f))
* **admin:** fit assignment route gate labels ([73339b9](https://github.com/icoretech/codex-pooler/commit/73339b96192ee037517b864f8044ccc01a65d42c))
* **admin:** keep circuit route paths readable ([146cbb9](https://github.com/icoretech/codex-pooler/commit/146cbb9cf254a42d220caa51b790e9bc7e5cd227))
* **admin:** keep circuit route paths readable ([45054ee](https://github.com/icoretech/codex-pooler/commit/45054eec44dec9c821f0402969d09f1a5da50e36))
* **admin:** present unknown model weekly resets ([bc5afe6](https://github.com/icoretech/codex-pooler/commit/bc5afe6c3c8bb919e43f45412ef7c207dcc2b710))
* **admin:** preserve distinct circuit display lanes ([3b48496](https://github.com/icoretech/codex-pooler/commit/3b4849650552365384df31fc401dbb6d668c4cd8))
* **deps:** update astro monorepo ([#216](https://github.com/icoretech/codex-pooler/issues/216)) ([94ee6ec](https://github.com/icoretech/codex-pooler/commit/94ee6ec7c5173009795d85071f2263660f8b36ca))
* **deps:** update dependency @astrojs/starlight to v0.41.5 ([#218](https://github.com/icoretech/codex-pooler/issues/218)) ([faa0723](https://github.com/icoretech/codex-pooler/commit/faa0723553f349dfcd8867ed9b9b52385989ad92))
* **deps:** update dependency daisyui to v5.7.4 ([#212](https://github.com/icoretech/codex-pooler/issues/212)) ([533d28a](https://github.com/icoretech/codex-pooler/commit/533d28afae9787eeacb3c4fa7176afc43861d3f8))
* **dev:** keep circuit seed states stable ([48db2df](https://github.com/icoretech/codex-pooler/commit/48db2df23601f275de6f6cfb242d29dde1ecbe43))
* **dev:** stabilize circuit demo route counts ([29f54d8](https://github.com/icoretech/codex-pooler/commit/29f54d8db21f1b94aa335caf451ddc2128c7036e))
* **gateway:** handle multipart rejection parts ([8f2b982](https://github.com/icoretech/codex-pooler/commit/8f2b98278be5ebfa4125c0156c5ef7db3b9a831a))
* **gateway:** omit code mode tools from direct metadata ([9b874da](https://github.com/icoretech/codex-pooler/commit/9b874dadd60660afa3b4fc6264fcc6a557357c17))
* **gateway:** remove stale req timeout branch ([9b228e6](https://github.com/icoretech/codex-pooler/commit/9b228e661083fe90038bb615186594f1f65bb945))
* **gateway:** retain bounded upstream rejection metadata ([7817bdf](https://github.com/icoretech/codex-pooler/commit/7817bdfd502b9161d0ed700cdc85186697400cb9))
* **gateway:** support req 0.7 transport changes ([f2e5452](https://github.com/icoretech/codex-pooler/commit/f2e54528085fc9fa115e60dcc9640b4525c5a1c3))
* **jobs:** read reconciliation pause from database ([1b1744e](https://github.com/icoretech/codex-pooler/commit/1b1744e32935694a7d4450d89e1aa861d60b29cf))
* **quota:** classify model weekly reset evidence ([62893ba](https://github.com/icoretech/codex-pooler/commit/62893bad616e0eb23bf278ca33ed07fc9e5247f9))
* **quota:** synchronize quota selection timestamps ([75611bc](https://github.com/icoretech/codex-pooler/commit/75611bcb9a18bc4e8d56b5d565cec424a01a3ae2))
* **saved-resets:** compare expiry horizon at whole seconds ([8b562e6](https://github.com/icoretech/codex-pooler/commit/8b562e65e1e9c8c005980d20b85748c5e08e8af4))
* **saved-resets:** compare reset buffer at whole seconds ([3668d77](https://github.com/icoretech/codex-pooler/commit/3668d77eae91377226226b5f53a487ada41d8413))
* **saved-resets:** rescue expiring credits without traffic ([10e96fd](https://github.com/icoretech/codex-pooler/commit/10e96fd953e1cdf0ca1fdbf72e446dc63c94f32e))
* **streaming:** bound public terminal stream failures ([ea2bd04](https://github.com/icoretech/codex-pooler/commit/ea2bd0411cf830fa8c758b3ed0e0038c9a75213c))
* **streaming:** preserve chunk errors and state in first-event flush ([e189931](https://github.com/icoretech/codex-pooler/commit/e189931570bde009a29662f253dfcb3c33ef804d))
* **streaming:** project public failed response envelopes ([834c1e8](https://github.com/icoretech/codex-pooler/commit/834c1e82b2cc5439f4137ad7c6387525ab92cd24))
* **streaming:** raise ordinary incomplete SSE block bound to 8 MiB ([a586178](https://github.com/icoretech/codex-pooler/commit/a586178fcb427b2352457c4dbada904e0171deed))
* **streaming:** record applicable overflow buffer limit ([8ca588a](https://github.com/icoretech/codex-pooler/commit/8ca588a4a00fbfdefb037022603e02131d52528f))
* **streaming:** retain large terminal candidates ([2fcef24](https://github.com/icoretech/codex-pooler/commit/2fcef242c1351846c50b2df40a2d9dea77658c42))
* **streaming:** sanitize malformed terminal errors ([4c94d76](https://github.com/icoretech/codex-pooler/commit/4c94d76c804a71d7f04c374d6a612d63819e6598))
* **streaming:** sanitize public terminal envelopes ([1f3deab](https://github.com/icoretech/codex-pooler/commit/1f3deab9b81119f0bb2e5ea14799c6af194de65c))
* **streaming:** surface interrupted public stream failures ([ef057dc](https://github.com/icoretech/codex-pooler/commit/ef057dc733ab09ec93c790817dc1839ab3648f70))
* **verification:** assert model weekly routing winner ([88d36bf](https://github.com/icoretech/codex-pooler/commit/88d36bf6f9181ae9b67fd73e6a19a098131ccbd1))
* **websocket:** preserve canonical terminal events ([e60fca0](https://github.com/icoretech/codex-pooler/commit/e60fca0052f507d92a174e4646827463b55d995b))
* **websocket:** surface owner-forwarded turn failures ([0443580](https://github.com/icoretech/codex-pooler/commit/04435806a3fe45cf852ff1d58774bceb4b56474b))


### Performance Improvements

* **streaming:** parse accumulated SSE incrementally without rescans ([b866e36](https://github.com/icoretech/codex-pooler/commit/b866e363225c9d6346f17766147fa7bf5ab5f7bc))

## [0.5.8](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.5.7...codex-pooler-v0.5.8) (2026-07-25)


### Bug Fixes

* **quota:** harden model weekly countdown anchoring ([3f6ca13](https://github.com/icoretech/codex-pooler/commit/3f6ca13d6667b4a7885498ba086b565cf400b7c7))

## [0.5.7](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.5.6...codex-pooler-v0.5.7) (2026-07-25)


### Features

* **admin:** lead the request-log row with its date and status ([a126883](https://github.com/icoretech/codex-pooler/commit/a1268832df019fd56986102c05eb71cafa25a7a8))
* **admin:** read the request duration with its outcome ([1c2dd6d](https://github.com/icoretech/codex-pooler/commit/1c2dd6de3406d487c7bbbaa6194299b585c8d2c3))
* **admin:** rebuild the jobs explorer row as a single ledger ([195af99](https://github.com/icoretech/codex-pooler/commit/195af997555c50226aeb796e9dad73608c0b12df))
* **admin:** regroup the request-log row and let it fit the screen ([d29dae5](https://github.com/icoretech/codex-pooler/commit/d29dae57c079da0d636f93f60abe39eab216d60b))
* **responses:** support programmatic tool calling ([cd97650](https://github.com/icoretech/codex-pooler/commit/cd97650e561afd11f3b57be11fc98f91e2f41054))


### Bug Fixes

* **admin:** make the whole request-log row open its drawer ([b7198ac](https://github.com/icoretech/codex-pooler/commit/b7198ac885cca8f825bb5907004401c5e8445193))
* **deps:** update plug_crypto to 2.2.0 ([ba779e7](https://github.com/icoretech/codex-pooler/commit/ba779e720240bba2791bb075bc6d0bff07ad2e52))
* **quota:** anchor started zero-percent model windows ([69494a2](https://github.com/icoretech/codex-pooler/commit/69494a2fec8b3bcb16f4139c0198ad4ac6b727a6))

## [0.5.6](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.5.5...codex-pooler-v0.5.6) (2026-07-24)


### Features

* **admin:** stand the stats leaderboard on olympic podium steps ([55d0559](https://github.com/icoretech/codex-pooler/commit/55d05596ecca2a36b1bd91a3b3fff1f7d045d411))


### Bug Fixes

* **deps:** update Ecto lock to 3.14.1 ([b3567c3](https://github.com/icoretech/codex-pooler/commit/b3567c3e97bf399c778ffc22c917fae2c3f41b86))
* **deps:** update lazy_html to 0.1.12 ([c1f6977](https://github.com/icoretech/codex-pooler/commit/c1f69779639325b9b72ec84f7f452516eb76ef4c))
* **websocket:** classify upstream response event families ([e2a95a4](https://github.com/icoretech/codex-pooler/commit/e2a95a46282190fa36816c0d1ca13c948ad851f9))
* **websocket:** keep continuations on their originating connection ([c1c2da6](https://github.com/icoretech/codex-pooler/commit/c1c2da6d8ca4407f1ec2bb3377030c554d6cc8f5))
* **websocket:** persist causal termination diagnostics ([25e860c](https://github.com/icoretech/codex-pooler/commit/25e860c44fd3a3607cfcadc0c9dc9e1fbddf016a))

## [0.5.5](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.5.4...codex-pooler-v0.5.5) (2026-07-24)


### Features

* **websocket:** record bounded upstream terminal diagnostics ([9dc076e](https://github.com/icoretech/codex-pooler/commit/9dc076e9595016e76695f4529d11353173cb11d7))


### Bug Fixes

* **admin:** keep quota reset timers and usage bounds clear ([0f4f955](https://github.com/icoretech/codex-pooler/commit/0f4f95595c70e74f5392b716806280eeffab764f))
* **deps:** update dependency @astrojs/starlight to v0.41.4 ([#205](https://github.com/icoretech/codex-pooler/issues/205)) ([2ae48ed](https://github.com/icoretech/codex-pooler/commit/2ae48edbd2a02b176b21eaad435e11d2097172ce))
* **endpoint:** serve HTTP/1.1 only on the cleartext listener ([552c999](https://github.com/icoretech/codex-pooler/commit/552c9998203e86751494b975eff712fab0c9aeda))
* preserve saved reset discovery timestamps ([2848445](https://github.com/icoretech/codex-pooler/commit/2848445374627596a817af11c3da959acdb9addf))
* **streaming:** classify visible stream failures neutrally ([9acba38](https://github.com/icoretech/codex-pooler/commit/9acba383be3e77f5a6f4591895d3cfe34b27fd46))
* **streaming:** preserve clean EOF settlement ([ecdf221](https://github.com/icoretech/codex-pooler/commit/ecdf22144394b2501201a6ee9e2c78814ebfdfd4))
* **websocket:** log failed native turns safely ([3f73b88](https://github.com/icoretech/codex-pooler/commit/3f73b884fb90c85ecbe283da9d9b34b7e946400b))
* **websocket:** record bounded owner exit causes ([fa23be4](https://github.com/icoretech/codex-pooler/commit/fa23be4380fd980832d8b9bfceaba7eb2c746019))
* **websocket:** sanitize native turn failure logs ([410fa87](https://github.com/icoretech/codex-pooler/commit/410fa8718092d3d793bc8500cd5c28c8e3a3fa81))

## [0.5.4](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.5.3...codex-pooler-v0.5.4) (2026-07-23)


### Features

* **gateway:** let rollout drain finish in-flight websocket turns ([11af461](https://github.com/icoretech/codex-pooler/commit/11af4612c99bd867f68e675fbcb571cf63237ab1))
* **gateway:** retry bridged turns over HTTP when the peer dies pre-content ([8f89c10](https://github.com/icoretech/codex-pooler/commit/8f89c10769791b8be32f9d93bc2f5081d6b50e03))


### Bug Fixes

* **saved-resets:** harden the auto-consume latch against review findings ([06cadea](https://github.com/icoretech/codex-pooler/commit/06cadea82de6854bb35001f7cfeda0747a603e6c))
* **saved-resets:** latch automatic redemption until post-consume quota converges ([228ca44](https://github.com/icoretech/codex-pooler/commit/228ca445bbe69402c2d0b83ddb6942d1366c3f52))

## [0.5.3](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.5.2...codex-pooler-v0.5.3) (2026-07-22)


### Bug Fixes

* **routing:** extend the skip policy to circuit writes and pin lock-test backends ([f2671ad](https://github.com/icoretech/codex-pooler/commit/f2671adc7550f6a6cb00622acb90859ff31b185c))
* **routing:** take canonical reference locks in side-effect writers ([5b40f69](https://github.com/icoretech/codex-pooler/commit/5b40f69cba5b43b6a189f8b4fd8753144e8cb59d))
* **websocket:** recover frames handed back beside a coalesced transport error ([cb3a312](https://github.com/icoretech/codex-pooler/commit/cb3a312568c46042e1dff665ff8e4f378f4d1442))

## [0.5.2](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.5.1...codex-pooler-v0.5.2) (2026-07-22)


### Features

* **accounting:** count known usage settlements ([4206ae2](https://github.com/icoretech/codex-pooler/commit/4206ae23bc1f37672346c0abfbbd787d063639d5))
* **admin:** classify token usage completeness ([61d32c7](https://github.com/icoretech/codex-pooler/commit/61d32c7641d2d3d05477376c98607f95a70cc430))
* **admin:** distinguish floating quota resets ([a57cbfe](https://github.com/icoretech/codex-pooler/commit/a57cbfeebea179c03e255b33550522c7e905fc9c))
* **admin:** expose quota and usage certainty ([7d22c92](https://github.com/icoretech/codex-pooler/commit/7d22c92524ce6258061aca11b92855d8290e167c))
* **admin:** open the saved reset bank from the banked resets block ([de90929](https://github.com/icoretech/codex-pooler/commit/de909298bbccae2bd6c97f5db9912947d66234b2))
* **gateway:** add immutable reset probe context ([98ea953](https://github.com/icoretech/codex-pooler/commit/98ea953c20fc2c7cdf1cba5b252d31be22d9eb63))
* **streaming:** observe usage before truncation ([b338e8f](https://github.com/icoretech/codex-pooler/commit/b338e8f1b9dcf190d16decb791fd52d95a33afa8))
* **telemetry:** expose usage and quota decisions ([e8988e4](https://github.com/icoretech/codex-pooler/commit/e8988e427ea592e47e05f9e09e0cfc4b67cc8bf7))


### Bug Fixes

* **accounting:** persist websocket terminal failure context ([fc881bb](https://github.com/icoretech/codex-pooler/commit/fc881bb8256c899d5c8df52ca62ab6e9adfef84d))
* **admin:** let the token burn popover escape the account card panels ([4f254d5](https://github.com/icoretech/codex-pooler/commit/4f254d5004f1615b269fec2eb30163f4a537f525))
* **deps:** update dependency astro to v7.1.3 ([#197](https://github.com/icoretech/codex-pooler/issues/197)) ([e7638d8](https://github.com/icoretech/codex-pooler/commit/e7638d8e1f984f78375a3c788ff954cff1c89602))
* **deps:** update dependency daisyui to v5.7.0 ([#200](https://github.com/icoretech/codex-pooler/issues/200)) ([61295c8](https://github.com/icoretech/codex-pooler/commit/61295c81a19cdf6378259a5da2b31c2c067e6f84))
* **gateway:** confirm scoped probes on success ([2d65eb4](https://github.com/icoretech/codex-pooler/commit/2d65eb44085086acea3bdbcf18547dc407770267))
* **gateway:** reject reset probe scope drift ([9c13632](https://github.com/icoretech/codex-pooler/commit/9c13632d366cfdf3dca6f3b8ef2693341f51ff26))
* **observability:** distinguish websocket terminal delivery failures ([1271063](https://github.com/icoretech/codex-pooler/commit/12710638c9d2b2501b7f94034f337ca08ac98ecd))
* **quota:** confirm provider reset cycles durably ([e1b0898](https://github.com/icoretech/codex-pooler/commit/e1b0898c064cd5ebe48abcedfb13fdcf245f5544))
* **quota:** prefer freshest logical window evidence ([437fae5](https://github.com/icoretech/codex-pooler/commit/437fae572e75480ee123bbaa5afaee15b23210e1))
* **quota:** reject superseded windows before folding ([5e25bed](https://github.com/icoretech/codex-pooler/commit/5e25bedba3bee03f7a55b3502f1556e4e73d8091))
* **routing:** bind probes to one eligible route ([d2f272f](https://github.com/icoretech/codex-pooler/commit/d2f272f25e076f673a206a60a6886158647f4a4a))
* **saved-resets:** block reused consumed credits ([e671b1f](https://github.com/icoretech/codex-pooler/commit/e671b1f2798b9785251c111de0232aad90945145))
* **saved-resets:** serialize scoped probe leases ([bd055c0](https://github.com/icoretech/codex-pooler/commit/bd055c020e87fffefac498f40ddaaaa0738f9ab6))
* **streaming:** keep reset probes on one SSE attempt ([ac20fd9](https://github.com/icoretech/codex-pooler/commit/ac20fd92308965b3737ce5ac97ea898f74d20b14))
* **streaming:** preserve committed websocket outcomes ([3ec2952](https://github.com/icoretech/codex-pooler/commit/3ec2952b6812717bdd0b57d204e47655edfb48c7))
* **streaming:** preserve observed usage through finalization ([71bf4e1](https://github.com/icoretech/codex-pooler/commit/71bf4e1323d4c48a81cbb096faec38c45787e880))
* **streaming:** retain websocket bridge attempt diagnostics ([08712b4](https://github.com/icoretech/codex-pooler/commit/08712b4597097cac26a708afddb0556c06b1f0df))
* **streaming:** serialize websocket timeout commitment ([6c894ea](https://github.com/icoretech/codex-pooler/commit/6c894ea73a0598acbe3db00d4b0d1b9575f6554f))
* **websocket:** add terminal race controls and connection invalidation ([686fe7e](https://github.com/icoretech/codex-pooler/commit/686fe7e38ddc1e6743769b04fe288e7ed35c0ffc))
* **websocket:** carry scoped probes through upstream sessions ([f46a0bd](https://github.com/icoretech/codex-pooler/commit/f46a0bd03563f0c54dda085826bcf1fa0da184fc))
* **websocket:** disable owner recovery for reset probes ([3aef7af](https://github.com/icoretech/codex-pooler/commit/3aef7af2604fa1be66638a4cd7f61726770daa8c))
* **websocket:** finalize reset probes without retries ([0e2bf2e](https://github.com/icoretech/codex-pooler/commit/0e2bf2ea8d3124633af4a9a4b746fe44a77b8468))
* **websocket:** keep unassigned owner turns soft ([8405344](https://github.com/icoretech/codex-pooler/commit/8405344ba35621b1c42f7019bcc3f9a71efd3081))
* **websocket:** mark post-send transport failures committed ([04e08bb](https://github.com/icoretech/codex-pooler/commit/04e08bb88a32abc3fe0ff25c44eaa5d0a26b1d66))
* **websocket:** preserve terminal delivery before owner settlement ([d1184d9](https://github.com/icoretech/codex-pooler/commit/d1184d9a23e9bcd7d121d8b8fed069a34113c0b8))


### Performance Improvements

* **observatory:** index recent outcome lookups ([8a16934](https://github.com/icoretech/codex-pooler/commit/8a16934a93654dad8fdd1ae32ee9975beda417e9))

## [0.5.1](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.5.0...codex-pooler-v0.5.1) (2026-07-21)


### Features

* **admin:** add pool model serving controls ([08eb716](https://github.com/icoretech/codex-pooler/commit/08eb716541ab2c3cba0c0647f9b32c88706bc122))
* **admin:** compact the model serving panel into a scannable table ([0305902](https://github.com/icoretech/codex-pooler/commit/03059023a34b5da94f573a8496ac29e070b9ab23))
* **admin:** ground the pool details step in lifecycle semantics ([5c2bec0](https://github.com/icoretech/codex-pooler/commit/5c2bec04b991aa8251d4ce15ca5f08ee3cb8b5d8))
* **admin:** let pool assignment lists use the available dialog height ([7374d17](https://github.com/icoretech/codex-pooler/commit/7374d174e9fd91de70bf3f88e9be4c1bbf2cb110))
* **admin:** mark selected assignment cards and inline the count chip ([09ec3e1](https://github.com/icoretech/codex-pooler/commit/09ec3e11a788f68d0494bbb3a7bbf0dcdb1f0a5d))
* **admin:** merge pool step headings into the dialog header ([2cf7a60](https://github.com/icoretech/codex-pooler/commit/2cf7a6015538f9df18336fbe461ce5912a764319))
* **admin:** show pool routing strategies as explained cards ([6b0277e](https://github.com/icoretech/codex-pooler/commit/6b0277efe2140f7098b5aeff662b08f7eddc5bdd))
* **gateway:** apply pool model serving modes ([442ed39](https://github.com/icoretech/codex-pooler/commit/442ed39b20001e53199ef27d862e54d3555e5905))
* **pools:** persist per-model serving modes ([6364692](https://github.com/icoretech/codex-pooler/commit/6364692c6399025973d82d115553f449f10414f4))


### Bug Fixes

* **admin:** sort model serving rows newest-first ([3ed523b](https://github.com/icoretech/codex-pooler/commit/3ed523b0742e7ad91c839d8a43d3bddee83e6cf9))
* bridge audio input through compaction ([eac13d1](https://github.com/icoretech/codex-pooler/commit/eac13d19705e27432a9dd2c75d220db96d4b9382))
* **gateway:** harden websocket terminal and lock handling ([ed17839](https://github.com/icoretech/codex-pooler/commit/ed17839d99d11d4bab29f8896c4ad24230f975ca))
* **gateway:** harden websocket terminal and lock handling ([8ae030a](https://github.com/icoretech/codex-pooler/commit/8ae030a0cc12c16857365a5911bedfd7f11b5703))
* preserve response terminal and owner recovery behavior ([1e8e5ad](https://github.com/icoretech/codex-pooler/commit/1e8e5ade3772c9bc4bf70102b60c5bb474e8cedd))

## [0.5.0](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.4.33...codex-pooler-v0.5.0) (2026-07-19)


### Features

* **admin:** add an Observatory nav link with a celestial icon ([c575797](https://github.com/icoretech/codex-pooler/commit/c5757974d4d66057583c25a24f2930a41b7f5fef))
* **admin:** manage image generation policy ([bd7d9c4](https://github.com/icoretech/codex-pooler/commit/bd7d9c41074453b662456cb9d4d38246f52f0cd1))
* **admin:** surface Observatory access on API keys and refine the rows ([c4c0ebe](https://github.com/icoretech/codex-pooler/commit/c4c0ebe45945e098df66c411c09ec01a060e45a2))
* **observatory:** add per-key usage dashboard ([07dd826](https://github.com/icoretech/codex-pooler/commit/07dd826eae9ce3f75e06be256ddb84f7771c6466))
* **observatory:** drop latency/throughput, align model tints, refine mobile ([89aae6d](https://github.com/icoretech/codex-pooler/commit/89aae6dc3a981ad57c537821231fa440e8319e4e))
* **observatory:** drop the key prefix from the dashboard toolbar ([c8b1410](https://github.com/icoretech/codex-pooler/commit/c8b1410ce624f1aba94fea6f20acc25c5c5dd2f5))
* **observatory:** rework facts, model distribution, and toolbar ([5e31b58](https://github.com/icoretech/codex-pooler/commit/5e31b58d049bad6dd7fb582241646d36db85190d))
* **observatory:** rework the dashboard chart, header, and layout ([f98e92c](https://github.com/icoretech/codex-pooler/commit/f98e92c8f92bd660901c8a4b9bb5244afab1bad1))
* **observatory:** spin the pressed window button instead of a badge ([2bc4469](https://github.com/icoretech/codex-pooler/commit/2bc44696255b4b96b8eb3037f679008b24117890))
* **openai:** accept bounded Responses audio formats ([0dd89da](https://github.com/icoretech/codex-pooler/commit/0dd89da435c75929a7f796ae18cd74ade6983ad1))
* **pools:** add image generation permission ([d419baa](https://github.com/icoretech/codex-pooler/commit/d419baabc386c14507d342ca0a8d80f93be8da9d))
* **pools:** expose image generation policy ([a9f0141](https://github.com/icoretech/codex-pooler/commit/a9f0141ace6d71f9ee75337d31825be12ae73903))
* **pools:** project image generation policy ([e77e528](https://github.com/icoretech/codex-pooler/commit/e77e528615833e8c21fd8d4c3e712992fdb66bc4))
* **runtime:** enforce pool image generation policy ([d1c03e8](https://github.com/icoretech/codex-pooler/commit/d1c03e8b4622e79ec094f2d3a1e34eb288d56b64))


### Bug Fixes

* **admin:** clear upstream cockpit quality warnings ([ffc8aab](https://github.com/icoretech/codex-pooler/commit/ffc8aab86dc3aaa8a48cd616782f54a0bbbe2d0b))
* **deps:** update dependency astro to v7.1.1 ([#191](https://github.com/icoretech/codex-pooler/issues/191)) ([1c18d01](https://github.com/icoretech/codex-pooler/commit/1c18d017c0a6713c5b82c32b5248a362a5b7c477))
* **gateway:** remove retired websocket bridge gate ([e50523c](https://github.com/icoretech/codex-pooler/commit/e50523c0f5c84c7173935495b744afc103e66174))
* **gateway:** route native image requests through visible capacity ([f0fec85](https://github.com/icoretech/codex-pooler/commit/f0fec85f3f321fc1cd48ac1f69a89a3fa3262aa3))
* **observatory:** stop the per-key read timing out on the settlement join ([b271250](https://github.com/icoretech/codex-pooler/commit/b2712508d74c6957172cad7d8e4253c05ca72c7a))
* **openai:** tighten bounded audio handling ([d995718](https://github.com/icoretech/codex-pooler/commit/d99571814fcfbf53a70fbb33756770011f3622dc))
* **quota:** require live provider advance for idle reanchors ([60ab78d](https://github.com/icoretech/codex-pooler/commit/60ab78d5b38d8655126a7d4f66a63361958059d9))
* **streaming:** keep completed tool items terminal-only ([4b32b2d](https://github.com/icoretech/codex-pooler/commit/4b32b2d88636982da1a53b0d5aa20ed7ec94ea9f))


### Performance Improvements

* **admin:** move the pools traffic read off the LiveView process ([eb2a84d](https://github.com/icoretech/codex-pooler/commit/eb2a84d1d7e6b818de25e1b8c83c022160fd635f))
* **observatory:** collapse the four aggregate reads into one grid scan ([a260136](https://github.com/icoretech/codex-pooler/commit/a2601367197ca064f76daaa7d0b9d6060a62317c))
* **observatory:** read per-key tokens and cost from the fact projection ([4ba7a4c](https://github.com/icoretech/codex-pooler/commit/4ba7a4cd268665f9d78dcbe199e3cb68db10a7d7))


### Miscellaneous Chores

* release 0.5.0 ([7d3571f](https://github.com/icoretech/codex-pooler/commit/7d3571fbc8229ca1f6a6bbb5ee088f07d7cedf19))

## [0.4.33](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.4.32...codex-pooler-v0.4.33) (2026-07-17)


### Features

* **admin:** collapse cockpit expiration rows under the meter row ([a683c01](https://github.com/icoretech/codex-pooler/commit/a683c01c667ea45f494256147644bba6c4fdc6b4))
* **admin:** fold oauth relink activity into the cockpit rail ([717babe](https://github.com/icoretech/codex-pooler/commit/717babe77a2e21a1c1e7bdef72a137269dd51c8a))
* **admin:** give the cockpit the standard page header ([328213b](https://github.com/icoretech/codex-pooler/commit/328213bec63372208bc17537548507b21b7d0e78))
* **admin:** link pool compat flags to their documentation ([469b2c0](https://github.com/icoretech/codex-pooler/commit/469b2c0690bc78c3d51645fc7495db5f74ab5e00))
* **admin:** mark the websocket bridge pool flag experimental ([4daf45b](https://github.com/icoretech/codex-pooler/commit/4daf45ba5348e257170e14d810966e676cd3bebd))
* **admin:** name the redemption phase on the meter policy line ([2fe86ba](https://github.com/icoretech/codex-pooler/commit/2fe86ba77dc858b826b65ec45047881b8b37474a))
* **admin:** quota-style saved reset expiration rows ([b6723e5](https://github.com/icoretech/codex-pooler/commit/b6723e5ef28b5d8b9a24fa46c022b73c45704c24))
* **admin:** rebuild saved reset dialog as summary-first ([ad09b01](https://github.com/icoretech/codex-pooler/commit/ad09b01e0f43cab98060ffa098ce12b105990427))
* **admin:** ride the redemption lifecycle on the first meter segment ([6adcd00](https://github.com/icoretech/codex-pooler/commit/6adcd001ddec902d69fcf2f8a25c941ac10ebc49))
* **admin:** tell the connection story in the live-updates popover ([5d2921d](https://github.com/icoretech/codex-pooler/commit/5d2921d381808d4c24212817944025500f3b09b3))
* **admin:** trigger-mode radio cards for the saved reset policy ([687bd93](https://github.com/icoretech/codex-pooler/commit/687bd93d9c4a2ab4a61a5f946204ca62bf30b5d7))


### Bug Fixes

* **admin:** anchor 11px clock icons to the baseline, not the line box ([87cb84d](https://github.com/icoretech/codex-pooler/commit/87cb84d0b419f9668299f27cd1c5ee972ac6c9d1))
* **admin:** hide lane labels that repeat the account name ([f5a1d95](https://github.com/icoretech/codex-pooler/commit/f5a1d95517a6dcf300c3bd551a66f3711ecc7a8d))
* **admin:** hide owner-only Operators nav item from instance admins ([a1682fe](https://github.com/icoretech/codex-pooler/commit/a1682fe6815fb3c318ea7f2eb68dff0b2038ff9f))
* **admin:** keep lane reconciliation visible under long account labels ([7515ca0](https://github.com/icoretech/codex-pooler/commit/7515ca0e5fcfc854d0004a8ef7835359fc8788a0))
* **admin:** repaint the connection icon as soon as navigation lands ([35f15f9](https://github.com/icoretech/codex-pooler/commit/35f15f92c5b8506f05906acfbbe0c047182a7ad1))
* **admin:** show one disconnect banner, not both ([bf45be1](https://github.com/icoretech/codex-pooler/commit/bf45be1fc95d70b665dba67e9a7daf1911d5bbd0))
* **admin:** stop event reloads from wiping open dialog selections ([66d04a8](https://github.com/icoretech/codex-pooler/commit/66d04a883e7aea366712beedbf932a6e1607dbc5))
* **alerts:** deliver the v2 saved-reset evidence timestamps ([1c4aa70](https://github.com/icoretech/codex-pooler/commit/1c4aa70a6984954a2186127e1ce441841a12c326))
* **deps:** update dependency astro to v7.1.0 ([#185](https://github.com/icoretech/codex-pooler/issues/185)) ([a7c829f](https://github.com/icoretech/codex-pooler/commit/a7c829f2120bb42c335d65f7fcefb957400c2275))
* **mcp:** return explicit capability denial from operator metadata tools ([dc09c35](https://github.com/icoretech/codex-pooler/commit/dc09c35e8a70caaf1deba58809067ccaabeddfeb))
* **openai:** normalize Responses tool-output image detail ([434cbc3](https://github.com/icoretech/codex-pooler/commit/434cbc34483bfbbdd92b510d542ec7677d9f2d74))
* **openai:** preserve tool-output cache breakpoints ([fee62b0](https://github.com/icoretech/codex-pooler/commit/fee62b095c3461e87af12012f265aeba541b31b0))

## [0.4.32](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.4.31...codex-pooler-v0.4.32) (2026-07-17)


### Features

* **admin:** redesign upstream cockpit as identity console ([349f24f](https://github.com/icoretech/codex-pooler/commit/349f24f17f1fdecd33acbef5710a30c88f354f8c))
* **admin:** show websocket connection generations ([0fc8621](https://github.com/icoretech/codex-pooler/commit/0fc862119b19c6f4975a03125b720e041f05eadc))
* **admin:** visualize cumulative traffic distribution ([d2a6c7c](https://github.com/icoretech/codex-pooler/commit/d2a6c7c0057f2c75ba6015344bd67e0d733596a3))
* **gateway:** record websocket connection generations ([181a05d](https://github.com/icoretech/codex-pooler/commit/181a05de0c0a44b9f17ca961ef1f2063af5ea119))
* **settings:** configure websocket owner idle retention ([55acbe9](https://github.com/icoretech/codex-pooler/commit/55acbe943e6eac74ef08b69fe2eb85ef51b30c81))


### Bug Fixes

* **admin:** show ten stats leaderboard entries ([fc7b407](https://github.com/icoretech/codex-pooler/commit/fc7b4075c2312291c272b3f9cd7888f435e49f32))
* **admin:** size pool cards independently in the grid ([6d9034e](https://github.com/icoretech/codex-pooler/commit/6d9034ed5ff2d234bc76957dffe7ef9d66b92c0a))


### Performance Improvements

* **admin:** open request-log details without scanning the requests table ([bf59431](https://github.com/icoretech/codex-pooler/commit/bf594313cfb304ed8ad863e78e9e0a6921f7420b))

## [0.4.31](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.4.30...codex-pooler-v0.4.31) (2026-07-15)


### Features

* **admin:** add token-burn gated shine to quota meters ([0c1d952](https://github.com/icoretech/codex-pooler/commit/0c1d9521fa100c4e5999c7fdaa2f2c953cc3d2c1))
* **admin:** backport upstream footer hover to pool card metrics ([b9b53c2](https://github.com/icoretech/codex-pooler/commit/b9b53c285aa3690d0ecce2b67e3348ac7d0d2643))
* **admin:** collapse the reconciliation banner into a disclosure ([32a60e9](https://github.com/icoretech/codex-pooler/commit/32a60e9c620c7c7b2151ec88404ff328acde6906))
* **admin:** name the selected window in the leaderboard subtitle ([e7c2192](https://github.com/icoretech/codex-pooler/commit/e7c21927a2df881d13ae0d23d091da41d2f67e4b))
* **admin:** rank the stats leaderboard by tokens or settled cost ([a841419](https://github.com/icoretech/codex-pooler/commit/a8414192db23420c881c1362b6d3f54c4e88f4f8))
* **admin:** redesign request log rows with a fixed two-line budget ([0738e24](https://github.com/icoretech/codex-pooler/commit/0738e2429842e9fb78d4dad0bc8e1d1d6e559a28))
* **admin:** redesign stats dashboard and shared card chrome ([51639e7](https://github.com/icoretech/codex-pooler/commit/51639e78382d39965ffc41939622781d1be049f2))
* **admin:** render pool route gates as chevron flow ([f2a4156](https://github.com/icoretech/codex-pooler/commit/f2a4156661b0bb818989e9264f2ca10822e0c1ba))
* **admin:** show styled series legends on stats charts ([2676f66](https://github.com/icoretech/codex-pooler/commit/2676f668555de1d5b7e6ce8b85308f04c366ff6d))
* **admin:** split API key enforcement into its own wizard step ([d9389b4](https://github.com/icoretech/codex-pooler/commit/d9389b46568ba0d5f7e0911b6fdfbcd045f5a7a3))
* **admin:** toggle pool compat flags from the pool cards ([f5b757b](https://github.com/icoretech/codex-pooler/commit/f5b757b1b6b46f3b098d6cded6d5d8ecf3b00fd9))


### Bug Fixes

* **quota:** harden weekly restart evidence convergence ([0282a7d](https://github.com/icoretech/codex-pooler/commit/0282a7d5685fc97a9171df545229ae5cbd6771d8))

## [0.4.30](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.4.29...codex-pooler-v0.4.30) (2026-07-15)


### Features

* **gateway:** bridge public streaming turns over upstream websocket sessions ([3d9a423](https://github.com/icoretech/codex-pooler/commit/3d9a4232d3b6fc5991d2a98f219e1674e43157ec))
* **pools:** add the upstream websocket bridge routing toggle ([c8bc559](https://github.com/icoretech/codex-pooler/commit/c8bc559806debe30c90124dd47564f825d2d1314))


### Bug Fixes

* **admin:** break token leaderboard ties by descending model name ([b139878](https://github.com/icoretech/codex-pooler/commit/b139878260144786dfdef5bbabae02db4b2af531))
* **admin:** compact the API key rows below the columnar breakpoint ([0c4ed56](https://github.com/icoretech/codex-pooler/commit/0c4ed5691bd8f0408978b90e25d75b25863f232c))
* **admin:** line up the API key pool header elements ([da477bb](https://github.com/icoretech/codex-pooler/commit/da477bb1aa7fc1b98634223cf66213ac547e2e73))
* **admin:** make the API key group sort a total order ([b4c25f4](https://github.com/icoretech/codex-pooler/commit/b4c25f4b94a177f1e6641162810491741cbec581))
* **admin:** order API keys by lifecycle within each pool group ([b32348c](https://github.com/icoretech/codex-pooler/commit/b32348cef41aed68ceaf8de7b28745434516a781))
* **admin:** pin the API key status badge and label the prefix block ([baa3d4c](https://github.com/icoretech/codex-pooler/commit/baa3d4c7f4b2bd0feabb367daf8614d723f7bd08))
* **admin:** plain-face the key prefix and shorten the pool eyebrow ([27683e0](https://github.com/icoretech/codex-pooler/commit/27683e0f673b6f3ea893dcf12acc8e8b8274ad27))
* **admin:** size the key prefix value like its sibling facts ([9177d9f](https://github.com/icoretech/codex-pooler/commit/9177d9fb3a1a48b246bc661b0bf360e5bd24d5d3))
* **admin:** summarize the tokens panel with spend instead of tokens ([62df862](https://github.com/icoretech/codex-pooler/commit/62df8629438023f1f8994a8845e08d681c2332f9))
* **deps:** update dependency astro to v7.0.9 ([#172](https://github.com/icoretech/codex-pooler/issues/172)) ([315a7cd](https://github.com/icoretech/codex-pooler/commit/315a7cd7b0eda1bd7754eee3fe6801ce48c48806))
* **gateway:** fall back on failed incomplete bridge terminals ([d866df6](https://github.com/icoretech/codex-pooler/commit/d866df6f6044041b81e332e3020ee413fde51a37))
* **gateway:** preserve web tool outputs during compression ([b0bce21](https://github.com/icoretech/codex-pooler/commit/b0bce21f78f75ad9557f24bab8a088ea92d9fece))
* **upstreams:** harden quota reconciliation state transitions ([d3be184](https://github.com/icoretech/codex-pooler/commit/d3be1849357fa18ff2e0832742ca5a79c6a00889))
* **upstreams:** reuse fresh weekly quota when the usage probe blips ([7df8c58](https://github.com/icoretech/codex-pooler/commit/7df8c5881f1f64bab50404521d21553d01e742de))

## [0.4.29](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.4.28...codex-pooler-v0.4.29) (2026-07-14)


### Features

* **admin:** rank per-model usage in the account tokens panel ([ce1e88b](https://github.com/icoretech/codex-pooler/commit/ce1e88b8999acd99a649cd83a3a97bc10f0a159b))
* **admin:** show each account's models as a plain routing list ([00060a2](https://github.com/icoretech/codex-pooler/commit/00060a2d0378c3437b3685cbafd5d879a80e4f5d))
* **dev-seeds:** surface routing badges and token burn in full seed ([7b851f1](https://github.com/icoretech/codex-pooler/commit/7b851f189280c9367ef8d6e195afde635a14ce44))
* **gateway:** fail over assignment-dropped models across transports ([3e7338a](https://github.com/icoretech/codex-pooler/commit/3e7338ae5d5e2ff0a9d296e46e29aaaaf3e87574))
* **gateway:** harden assignment-model failover transports ([e60fb7c](https://github.com/icoretech/codex-pooler/commit/e60fb7c96daef1739c0a448739d45001e12817c3))


### Bug Fixes

* **accounting:** make daily rollup increments conflict-safe ([81947db](https://github.com/icoretech/codex-pooler/commit/81947db0482eecab94b619cb0540916f8939e69b))
* **accounting:** prevent terminal request lifecycle races ([f7e6c7a](https://github.com/icoretech/codex-pooler/commit/f7e6c7ab7c1ba98edebe7529ee9337f2c88cc5ec))
* **accounting:** subtract rollups atomically on settlement replacement ([fef4e88](https://github.com/icoretech/codex-pooler/commit/fef4e88294a96ad1b4f1a5484aa3f75c74dcfbb9))
* **admin:** tidy the quota reconciliation banner ([41a5edd](https://github.com/icoretech/codex-pooler/commit/41a5edd45cf5e03b5de9359b1650d50d21902ed6))
* **catalog:** preserve partial upstream sync results ([6b58a89](https://github.com/icoretech/codex-pooler/commit/6b58a89f3ca73dcd7fe464f1d7ecfaf3d2f25d21))
* **deps:** update dependency astro to v7.0.8 ([#161](https://github.com/icoretech/codex-pooler/issues/161)) ([38b557b](https://github.com/icoretech/codex-pooler/commit/38b557b03abb99e36d0e33495d12da49aba7ab53))
* **deps:** update dependency starlight-page-actions to v0.7.0 ([#162](https://github.com/icoretech/codex-pooler/issues/162)) ([cf08d92](https://github.com/icoretech/codex-pooler/commit/cf08d92ab3def9e3c09b82128a65fee961eb71b1))
* **dev-seeds:** price seeded burn usage and count the third pool ([3c1b2fd](https://github.com/icoretech/codex-pooler/commit/3c1b2fd27208b4c250904952381b1708165df5a6))
* **gateway:** fence websocket inline refreshes by credential epoch ([995e910](https://github.com/icoretech/codex-pooler/commit/995e910fe8eb298fbc7634638aca304c195278d5))
* **jobs:** dedupe automatic reconciliation by upstream identity ([c0b13b2](https://github.com/icoretech/codex-pooler/commit/c0b13b263877dc1178dbd524f3437563008502c2))
* **upstreams:** fence late usage-probe refreshes by credential epoch ([2470c0f](https://github.com/icoretech/codex-pooler/commit/2470c0f4c72c9e7329747251f31487efaff8c00e))
* **upstreams:** recover stale refreshing identities ([dc90464](https://github.com/icoretech/codex-pooler/commit/dc90464ce1c59c4f952aadf2eeda6339bd5f5345))

## [0.4.28](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.4.27...codex-pooler-v0.4.28) (2026-07-14)


### Bug Fixes

* **gateway:** converge pending resets from runtime evidence ([cc78776](https://github.com/icoretech/codex-pooler/commit/cc78776af61ef9bae1772b678ee9d335261494d0))
* **saved-resets:** bound lifecycle grants and recover expired records ([43dc2f8](https://github.com/icoretech/codex-pooler/commit/43dc2f820e91cab7c7cff07d2acfcc01645d260c))

## [0.4.27](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.4.26...codex-pooler-v0.4.27) (2026-07-14)


### Features

* **admin:** render credit-backed quota meters with striped progress bars ([72ca0f5](https://github.com/icoretech/codex-pooler/commit/72ca0f593bf4f19f201cfdaa89bbde508243b3b5))
* **admin:** show reset confirmation lifecycle ([4f126d5](https://github.com/icoretech/codex-pooler/commit/4f126d5b109961b92c88f18316bddc1e51b55fd7))
* **gateway:** expose catalog ETags and normalize Codex request envelopes ([484bc37](https://github.com/icoretech/codex-pooler/commit/484bc371d15ab94e74f34a90691d57724c9f2797))
* **gateway:** support reasoning effort controls end-to-end ([69b1cca](https://github.com/icoretech/codex-pooler/commit/69b1ccabf432f8eb07acd8e36fcc19797f0adbb8))


### Bug Fixes

* **admin:** expose current quota reconciliation state ([838d7c1](https://github.com/icoretech/codex-pooler/commit/838d7c1cedbe3301771b05a01ab94dfe5cb4b511))
* **admin:** restore auth expiry card subtitle ([b628d7e](https://github.com/icoretech/codex-pooler/commit/b628d7ead6ab8cf359311d6861135ea528697264))
* **deps:** update dependency daisyui to ^5.6.18 ([#152](https://github.com/icoretech/codex-pooler/issues/152)) ([2d5b4e5](https://github.com/icoretech/codex-pooler/commit/2d5b4e5b2e99b21be4ae75b26a644fbfb46384ce))
* **gateway:** confirm reset probe on success ([527b2d4](https://github.com/icoretech/codex-pooler/commit/527b2d4624b1f94cf90f614e4d0fc7b8533c94b3))
* **quotas:** confirm restarts by their forward anchor ([7379623](https://github.com/icoretech/codex-pooler/commit/73796239f47ff189c36bc6719c6ac2d74414fcce))
* **quotas:** converge anchored restarts after cycle end ([501654d](https://github.com/icoretech/codex-pooler/commit/501654dd3530783feb708771166ff7a91ee674e1))
* **quotas:** converge weekly restarts from sliding live evidence ([810fbae](https://github.com/icoretech/codex-pooler/commit/810fbaec76e01846cf82e94cdc5db0125f0d1463))
* **quotas:** cover descriptors with declared-null windows ([a25fbf4](https://github.com/icoretech/codex-pooler/commit/a25fbf4e18fe5fce92b0874fa3a978af7669a3c1))
* **quotas:** purge quota rows stranded on ended cycles ([2986bb8](https://github.com/icoretech/codex-pooler/commit/2986bb847b98f8480fef50125c0ee5817b4ce6f7))
* **quotas:** stop prior-cycle stale rows from masking restarts ([eec2700](https://github.com/icoretech/codex-pooler/commit/eec2700f2b4257a80c2a94ea55a615d192a004be))
* **quotas:** validate post-reset evidence freshness ([6ea17aa](https://github.com/icoretech/codex-pooler/commit/6ea17aa880f1c7269a4ab30af02ec52572a5b3b7))
* **routing:** force-route the guarded reset probe ([f12f4eb](https://github.com/icoretech/codex-pooler/commit/f12f4eb94749537fd4b4896ddc1ab60349c3b659))
* **routing:** route guarded reset probe candidates ([e4c428b](https://github.com/icoretech/codex-pooler/commit/e4c428b1100267a664baa0d194ed4858c0c98efb))
* **saved-resets:** add one-shot probe lease ([3c58174](https://github.com/icoretech/codex-pooler/commit/3c5817463a00b204092d2e6db0e010f993bfdaf2))
* **saved-resets:** confirm resets from fresh quota ([ac646fe](https://github.com/icoretech/codex-pooler/commit/ac646fe354765979c55e379d7fbfc4c7d9dff1fa))
* **saved-resets:** model pending reset confirmation ([6c35d85](https://github.com/icoretech/codex-pooler/commit/6c35d85adafca874aada709560a922e69fbb1905))
* **saved-resets:** persist redemption idempotency ([6178b9e](https://github.com/icoretech/codex-pooler/commit/6178b9e48b47d7c997ee71b5e8c45a0228b28176))
* **tokenizer:** load CRLF rank files ([1242699](https://github.com/icoretech/codex-pooler/commit/1242699fb9da2f384b297448b2850480e6f2ff91))
* **upstreams:** guard definitive usage auth rejection ([c6ea3ca](https://github.com/icoretech/codex-pooler/commit/c6ea3cac7eca912e67fcc8a762beb508b19b0779))
* **upstreams:** recover relinked identity assignments together ([ff289f5](https://github.com/icoretech/codex-pooler/commit/ff289f523767d08e35ca517adcdd34de5340091e))

## [0.4.26](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.4.25...codex-pooler-v0.4.26) (2026-07-12)


### Features

* **accounting:** price cache write usage ([a307828](https://github.com/icoretech/codex-pooler/commit/a307828e413d4d2eed486ef36cd794e894fd49e3))
* **gateway:** pass through OpenAI prompt cache controls ([6ba169c](https://github.com/icoretech/codex-pooler/commit/6ba169c63528c133a7829ec082d68260201d1cb6))


### Bug Fixes

* **deps:** update dependency daisyui to ^5.6.17 ([#145](https://github.com/icoretech/codex-pooler/issues/145)) ([71f09c7](https://github.com/icoretech/codex-pooler/commit/71f09c7bcc7f2b37504b2d23265e9f95e4341412))
* **quotas:** enforce the effective window view on every quota surface ([e487d18](https://github.com/icoretech/codex-pooler/commit/e487d18fe5d3530a0bafd3c39efb6785b4a77e67))
* **quotas:** survive provider weekly-primary quota toggles read-side ([9db3aaf](https://github.com/icoretech/codex-pooler/commit/9db3aaf5b00317fdcaabc9692f043172b58fc807))

## [0.4.25](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.4.24...codex-pooler-v0.4.25) (2026-07-11)


### Features

* add fail-closed OpenAI pricing preflight ([85a78a1](https://github.com/icoretech/codex-pooler/commit/85a78a1124b44ea3935ad5c83a96fbee8014246c))
* **admin:** focus API keys on credential lifecycle ([cec65b9](https://github.com/icoretech/codex-pooler/commit/cec65b9139fb184592911b6a08606eeebdf122cd))
* **events:** add topic-scoped Pool subscriptions ([4e9f28d](https://github.com/icoretech/codex-pooler/commit/4e9f28d5f208b829d71e701b1a8dee50d3d24ddc))


### Bug Fixes

* **admin:** distinguish colliding quota cards ([e2979ef](https://github.com/icoretech/codex-pooler/commit/e2979efd085d1a4d9a7ffcbf4202749f6f7cbe37))
* **admin:** validate API key expiry before review ([d0fcdc7](https://github.com/icoretech/codex-pooler/commit/d0fcdc7411479d3d5f10e7359b1fbc71cd4079f8))
* **auth:** normalize Codex OAuth issuer URLs ([bb22bf8](https://github.com/icoretech/codex-pooler/commit/bb22bf8565ad22947a907178b6fb0c2095957d2c))
* **catalog:** remove unreachable pricing error fallback ([413d27d](https://github.com/icoretech/codex-pooler/commit/413d27da4659820ea6fa8fb37208ec01aab4f87a))
* **deploy:** start verifier release dependencies ([abbb3b2](https://github.com/icoretech/codex-pooler/commit/abbb3b26b2c3ab5e4fca96f60274c44153e1490b))
* **gateway:** retain concurrent quota events ([dd3f35e](https://github.com/icoretech/codex-pooler/commit/dd3f35edec7af90439cb2a8a7c6ea289d9c57ddd))
* **gateway:** sanitize backend response item ids ([019cca7](https://github.com/icoretech/codex-pooler/commit/019cca7dcf761a04da506a98a535edaa9e3a033d))
* **quota:** converge repeated provider snapshots ([99f383e](https://github.com/icoretech/codex-pooler/commit/99f383e194a73a2582edda9f3cb2554026c67d4d))
* **quota:** guard stale reset snapshots ([957a34a](https://github.com/icoretech/codex-pooler/commit/957a34a8456342f286528f4eb92875ddee383744))
* **quota:** keep free-plan usage consistent with credits ([6a73abf](https://github.com/icoretech/codex-pooler/commit/6a73abfd428d0b96cf61fdc4e08192096d5c7662))
* **quota:** merge same-window usage claims across backward reset drift ([79e0888](https://github.com/icoretech/codex-pooler/commit/79e0888e1482cd77911a93797a21ddf48bc38a0d))
* **quota:** purge implausible and expired quota evidence rows ([c6ad82e](https://github.com/icoretech/codex-pooler/commit/c6ad82e3356485a64ca0e674dc8db5df9e3b3a63))
* **quota:** reconcile usage evidence atomically ([e4e78a2](https://github.com/icoretech/codex-pooler/commit/e4e78a2512d19b4b208063f91a4ba39de397048f))
* **quota:** refresh dynamically stale evidence ([79a6846](https://github.com/icoretech/codex-pooler/commit/79a68461fd070e552fd0b898e120ceb43c1e4371))
* **quota:** refresh evidence after reset cycles ([28e17b8](https://github.com/icoretech/codex-pooler/commit/28e17b8c8466befaa3964e3a3a62e6180d51c632))
* **quota:** refresh stale relative evidence ([e7133a9](https://github.com/icoretech/codex-pooler/commit/e7133a9269e1e47319aead17bb8a233bb0943365))
* **quota:** refresh window liveness on rejected same-cycle usage snapshots ([e7bcb43](https://github.com/icoretech/codex-pooler/commit/e7bcb43d6c84ef131ae48c9f14109f718a93ae46))
* **quota:** reject relative weak-zero reset outliers ([10cead1](https://github.com/icoretech/codex-pooler/commit/10cead1b46b0bcabe6925e4219f8537768d47931))
* **quota:** remove unreachable reset fallback ([d722cb1](https://github.com/icoretech/codex-pooler/commit/d722cb1aff57b8180c45aa2fc0e4bfac59586d7a))
* remove auth JSON handoff banner ([2e95ab3](https://github.com/icoretech/codex-pooler/commit/2e95ab33b0d641e3e59499a3edaec8e30fd416c3))
* **upstreams:** require reauth after definitive usage rejection ([b8cc828](https://github.com/icoretech/codex-pooler/commit/b8cc828be0db739bd3098b706dc6e305741229a4))


### Performance Improvements

* **accounting:** aggregate Pool usage buckets in SQL ([9b9554b](https://github.com/icoretech/codex-pooler/commit/9b9554b1a2a7a45e086802a63c0bbebd3eff0299))
* **admin:** coalesce Pool usage refreshes ([90f3124](https://github.com/icoretech/codex-pooler/commit/90f31241faf4fd9ba52d871fb59881da076c5a0a))
* **dev:** speed up deterministic seed cleanup ([72125b1](https://github.com/icoretech/codex-pooler/commit/72125b1fea8da5b391195ec8dec45b930f537639))

## [0.4.24](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.4.23...codex-pooler-v0.4.24) (2026-07-10)


### Bug Fixes

* **admin:** keep observed zero-use quotas visible ([28fa875](https://github.com/icoretech/codex-pooler/commit/28fa87509601c889d883575f3cac0ea897592653))
* **gateway:** enforce canonical Codex user agent ([9bfd7bc](https://github.com/icoretech/codex-pooler/commit/9bfd7bc884440034c0ac9eccbb2ec4ebdba7f973))
* **gateway:** send trusted Codex client identity ([56d38f9](https://github.com/icoretech/codex-pooler/commit/56d38f95d545f188c247f02d491b32ce2a7231e0))

## [0.4.23](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.4.22...codex-pooler-v0.4.23) (2026-07-10)


### Features

* **admin:** redesign API key registries ([5bb9f73](https://github.com/icoretech/codex-pooler/commit/5bb9f7314f75fb2f7ce7b9a045b06db8e75337f6))


### Bug Fixes

* **admin:** show observed zero-use model quotas ([d58b818](https://github.com/icoretech/codex-pooler/commit/d58b81851bb468c65b3040a1cfc6ef129448dbab))
* **upstreams:** prevent weekly quota evidence rollback ([e7f5039](https://github.com/icoretech/codex-pooler/commit/e7f5039d2088a52e31f1f036974d5a027657c750))

## [0.4.22](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.4.21...codex-pooler-v0.4.22) (2026-07-09)


### Bug Fixes

* **gateway:** normalize ultra thinking alias ([1686028](https://github.com/icoretech/codex-pooler/commit/168602821caa8c64c7d387f7ee0d2d6cd3f998d6))
* **gateway:** support gpt-5.6 Responses Lite models ([7473e2c](https://github.com/icoretech/codex-pooler/commit/7473e2c3df5d3746ed50a132379a5ce3b5c10e64))
* **upstreams:** persist quota snapshots atomically ([fb9b517](https://github.com/icoretech/codex-pooler/commit/fb9b51782f2106ee938c573bc20128f94d6d0295))

## [0.4.21](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.4.20...codex-pooler-v0.4.21) (2026-07-09)


### Bug Fixes

* **catalog:** discover gpt-5.6 models ([8a02d79](https://github.com/icoretech/codex-pooler/commit/8a02d7949de980c25d539a9bdae78c3163c04163))

## [0.4.20](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.4.19...codex-pooler-v0.4.20) (2026-07-09)


### Bug Fixes

* **upstreams:** preserve explicit quota reset times ([ed935b7](https://github.com/icoretech/codex-pooler/commit/ed935b7233dcdf7fbc807f246f3e272ce8933992))
* **upstreams:** preserve usage quota against runtime rollbacks ([7526b8c](https://github.com/icoretech/codex-pooler/commit/7526b8c091ef38382f9bcee068849e2ff2cdda73))
* **upstreams:** stabilize quota reset evidence ([e97be7e](https://github.com/icoretech/codex-pooler/commit/e97be7ed1c35f565820a0e2698ad97baf3024617))
* **upstreams:** stabilize quota usage probing ([542cc6c](https://github.com/icoretech/codex-pooler/commit/542cc6c2f875488dac49e2659de55fcaacadc0a3))

## [0.4.19](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.4.18...codex-pooler-v0.4.19) (2026-07-09)


### Bug Fixes

* **admin:** align quota card percent semantics ([91c2fba](https://github.com/icoretech/codex-pooler/commit/91c2fba6ce042e356f4eaf36e799b2fd4927db27))
* **admin:** correct upstream quota card semantics ([6161bb3](https://github.com/icoretech/codex-pooler/commit/6161bb384a5725bf93e34ab84e5c2e356d54c0e6))
* **admin:** preserve model quota percent evidence ([6fc4f0e](https://github.com/icoretech/codex-pooler/commit/6fc4f0ed9bf2f548e943d905b19ddcbb7869412d))
* **deps:** update dependency daisyui to ^5.6.15 ([#127](https://github.com/icoretech/codex-pooler/issues/127)) ([74f0309](https://github.com/icoretech/codex-pooler/commit/74f0309ace36e838006fed1545d97d8662e1b175))
* **deps:** update dependency daisyui to ^5.6.16 ([#128](https://github.com/icoretech/codex-pooler/issues/128)) ([69a8477](https://github.com/icoretech/codex-pooler/commit/69a8477bd045fb16efad9bc276a231aa561237ff))
* **quotas:** hide unreported additional quota rows ([07a187a](https://github.com/icoretech/codex-pooler/commit/07a187a95348ecfee6a44b975d8057c04edb29ba))
* **quotas:** preserve monthly credit capacity ([a94efdb](https://github.com/icoretech/codex-pooler/commit/a94efdb497d71127888297af22808775dbdf0a3e))
* **quotas:** preserve useful model quota evidence ([9d623d8](https://github.com/icoretech/codex-pooler/commit/9d623d8449f2a05f4702b7dd497d87fd93ee9a1b))
* **quotas:** preserve useful upstream quota evidence ([7c60f46](https://github.com/icoretech/codex-pooler/commit/7c60f46ec3670a6803db51689edf36cb387299cd))
* **upstreams:** reuse ChatGPT Cloudflare cookies ([87fc5bf](https://github.com/icoretech/codex-pooler/commit/87fc5bfeed7726c383b0f958da219701b4820e8e))

## [0.4.18](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.4.17...codex-pooler-v0.4.18) (2026-07-08)


### Bug Fixes

* **admin:** align alert incident filters ([056e76f](https://github.com/icoretech/codex-pooler/commit/056e76f0c7141fe9db0859555f997bfe72216d32))
* **admin:** remove upstream subject badge ([b1b5e0c](https://github.com/icoretech/codex-pooler/commit/b1b5e0c97ea85a0f978c470590c891b83899cf7d))
* **gateway:** account websocket pre-visible close retries ([8189f9e](https://github.com/icoretech/codex-pooler/commit/8189f9e5204c5ca245b1718076b7cc0ed81ec2b6))
* **gateway:** retry fresh websocket pre-terminal closes ([2550163](https://github.com/icoretech/codex-pooler/commit/255016393f67d6667292c9882b7a1f44634b3c65))
* **quota:** merge usage snapshots over zero stream evidence ([f0ae360](https://github.com/icoretech/codex-pooler/commit/f0ae3609762be5ae9daf51951382743ace36777c))

## [0.4.17](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.4.16...codex-pooler-v0.4.17) (2026-07-08)


### Bug Fixes

* compress concatenated JSON object streams ([f2efb62](https://github.com/icoretech/codex-pooler/commit/f2efb62d0f877ebe9685f7d595417cd7c391c068))
* lock targeted oauth relink assignments ([f1a67e3](https://github.com/icoretech/codex-pooler/commit/f1a67e3014c0d2a19641e372b78efee81c6151bb))
* require pool assignment for targeted oauth relink ([f1f35f1](https://github.com/icoretech/codex-pooler/commit/f1f35f1274e1ba2c8526c58c168f8bbafb20d39c))

## [0.4.16](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.4.15...codex-pooler-v0.4.16) (2026-07-07)


### Bug Fixes

* **deps:** update dependency daisyui to ^5.6.14 ([#118](https://github.com/icoretech/codex-pooler/issues/118)) ([fcf173d](https://github.com/icoretech/codex-pooler/commit/fcf173d550850ed23978b669d897d5ec7d890548))
* **omp:** accept encrypted compaction replay items ([1f9b86f](https://github.com/icoretech/codex-pooler/commit/1f9b86ff5df40a50ec31a95e3573cf0fc030d267))
* **upstreams:** preserve selected workspace on relink ([157561f](https://github.com/icoretech/codex-pooler/commit/157561f8fadb79e9048d8593dd4b9a5d9a0082c0))

## [0.4.15](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.4.14...codex-pooler-v0.4.15) (2026-07-07)


### Bug Fixes

* align alerts admin filters and notifications ([a612b9a](https://github.com/icoretech/codex-pooler/commit/a612b9aeaaf2b3a1d0af56d680e2e76b2181fd78))
* **deps:** update dependency daisyui to ^5.6.13 ([#113](https://github.com/icoretech/codex-pooler/issues/113)) ([4d0870b](https://github.com/icoretech/codex-pooler/commit/4d0870be3723f3cd6fa6fb7fe621fa487e632370))
* **gateway:** raise runtime bulkhead defaults ([1eb01c5](https://github.com/icoretech/codex-pooler/commit/1eb01c5a92a291407ad7044625552a28af262414))
* send browser headers for Codex auth requests ([3ecf80e](https://github.com/icoretech/codex-pooler/commit/3ecf80e17c7c6e1f6e96120c64e162f0bf8e78db))

## [0.4.14](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.4.13...codex-pooler-v0.4.14) (2026-07-05)


### Bug Fixes

* **alerts:** align delivery error contracts ([956a0d4](https://github.com/icoretech/codex-pooler/commit/956a0d4b8beee6b41efcc456c34ee86e52ddea2f))
* **deps:** update dependency @astrojs/starlight to v0.41.3 ([#112](https://github.com/icoretech/codex-pooler/issues/112)) ([5df9ff3](https://github.com/icoretech/codex-pooler/commit/5df9ff3dc55897ee98de62cc49bcf9ce85641625))
* **deps:** update dependency apexcharts to ^5.16.0 ([#111](https://github.com/icoretech/codex-pooler/issues/111)) ([1e03485](https://github.com/icoretech/codex-pooler/commit/1e034857d0b52747fa26825ab8ad06d0b04977ff))
* **deps:** update dependency astro to v7.0.6 ([#109](https://github.com/icoretech/codex-pooler/issues/109)) ([0fd3cb4](https://github.com/icoretech/codex-pooler/commit/0fd3cb4dfa34a1d190f8417f72fb3489a98e5960))
* require upstream deletion confirmation ([9e26403](https://github.com/icoretech/codex-pooler/commit/9e264030c22a88f4225128b489d2caacdb2312bd))
* **tests:** stabilize persistent websocket keepalive timing ([4ad058a](https://github.com/icoretech/codex-pooler/commit/4ad058aeb93ad85ed3a4dd3ee5df358861daca21))

## [0.4.13](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.4.12...codex-pooler-v0.4.13) (2026-07-03)


### Bug Fixes

* **alerts:** dedupe saved reset first-seen incidents ([cf5773c](https://github.com/icoretech/codex-pooler/commit/cf5773cd9de4263f56d76f174a7103f9b96ad89c))
* **ci:** isolate Pages artifacts per rerun ([a3456f4](https://github.com/icoretech/codex-pooler/commit/a3456f4705beaa558032c8df631b98812a5478da))
* **ci:** skip Pages deploy for non-doc changes ([e903ef9](https://github.com/icoretech/codex-pooler/commit/e903ef91bd898011f19be8ace1110aa68902ea55))
* **deps:** update dependency astro to v7.0.5 ([#103](https://github.com/icoretech/codex-pooler/issues/103)) ([4047494](https://github.com/icoretech/codex-pooler/commit/40474942c3660e0817dddac0289d8e10698d22e2))
* **deps:** update dependency daisyui to ^5.6.10 ([#107](https://github.com/icoretech/codex-pooler/issues/107)) ([c3b5076](https://github.com/icoretech/codex-pooler/commit/c3b50762eee79d55a913655d6e4546af9d83693e))

## [0.4.12](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.4.11...codex-pooler-v0.4.12) (2026-07-02)


### Bug Fixes

* **deps:** update dependency daisyui to ^5.6.7 ([#104](https://github.com/icoretech/codex-pooler/issues/104)) ([78b014f](https://github.com/icoretech/codex-pooler/commit/78b014f8555eaa10b807f9bba6e16c9c1f06c599))

## [0.4.11](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.4.10...codex-pooler-v0.4.11) (2026-07-02)


### Features

* **alerts:** add saved reset first-seen alerts ([e354d38](https://github.com/icoretech/codex-pooler/commit/e354d38c7661a8260803cae6cacc762cd3b62319))


### Bug Fixes

* **admin:** refine operator settings layouts ([749a14f](https://github.com/icoretech/codex-pooler/commit/749a14f23b9898266fdf7117b1071630c3bce590))
* **admin:** stop inferring fast mode from model slug ([a71ee93](https://github.com/icoretech/codex-pooler/commit/a71ee936c6c81c648e2ba1ae0bd548fd375cd0c6))
* **deps:** update dependency @astrojs/starlight to v0.41.2 ([#102](https://github.com/icoretech/codex-pooler/issues/102)) ([d7bb5e0](https://github.com/icoretech/codex-pooler/commit/d7bb5e0ca4a78fc609bfdc926565520faa187370))
* **web:** set public page titles ([596ade7](https://github.com/icoretech/codex-pooler/commit/596ade7ba4e30b24cc2509821f3427c3fba4f686))
* **websocket:** align owner submit forwarding timeout ([8b00cde](https://github.com/icoretech/codex-pooler/commit/8b00cdeb3aaf847f783a927a177069da10cf594f))
* **websocket:** close stale upstream sessions after missed pong ([5d72516](https://github.com/icoretech/codex-pooler/commit/5d72516d285303bb0d5e50ce542291ec6f798bdb))

## [0.4.10](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.4.9...codex-pooler-v0.4.10) (2026-07-01)


### Features

* support none reasoning effort policy ([9eea1c2](https://github.com/icoretech/codex-pooler/commit/9eea1c2ff8322fc1915e94260e619eba5b724a0b))


### Bug Fixes

* **admin:** bound jobs failure projections ([09f390a](https://github.com/icoretech/codex-pooler/commit/09f390ae5cfcff3b4927f2af6639e47b45efdb87))
* **deps:** update dependency daisyui to ^5.6.6 ([#98](https://github.com/icoretech/codex-pooler/issues/98)) ([4482f82](https://github.com/icoretech/codex-pooler/commit/4482f825fffdcf1a2efba2db21d6eaec8bdde27b))
* **deps:** update docs site astro stack ([bab5b75](https://github.com/icoretech/codex-pooler/commit/bab5b75c9b68cce48c232ded6ad307fb7da94edd))
* **gateway:** make interrupted response streams retryable for omp ([27dfe52](https://github.com/icoretech/codex-pooler/commit/27dfe52792206718f7e9f8771a678cffb4689d5c))
* preserve lossy local shell outputs during compression ([cddb976](https://github.com/icoretech/codex-pooler/commit/cddb976b92ce815a000b2c452d46ff495ccbad27))
* support local Codex Desktop annotation ([ecae01e](https://github.com/icoretech/codex-pooler/commit/ecae01ecc84bc4f120ecbd1f01f9b6172c5ac263))

## [0.4.9](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.4.8...codex-pooler-v0.4.9) (2026-06-30)


### Bug Fixes

* **admin:** make manual saved-reset redemption account-level ([ca3ee9d](https://github.com/icoretech/codex-pooler/commit/ca3ee9d377bff72d71cf3dc5d5304e1c645db671))
* **deps:** update dependency daisyui to ^5.6.5 ([#96](https://github.com/icoretech/codex-pooler/issues/96)) ([0c0cdcc](https://github.com/icoretech/codex-pooler/commit/0c0cdcc78e0c220e0299a0bee99ddc47c1715c27))
* **gateway:** prevent saved-reset auto redemption before routeability ([27f9642](https://github.com/icoretech/codex-pooler/commit/27f96423436a2cb36afb8e3e9f7a7ae235e192b6))
* **upstreams:** flatten saved-reset redemption claim handling ([b7a327a](https://github.com/icoretech/codex-pooler/commit/b7a327a84fa5bdf3a08b0bc56a6910fc3be0fc23))
* **upstreams:** revalidate saved-reset auto claim assignments ([33c5ed8](https://github.com/icoretech/codex-pooler/commit/33c5ed896c0c6a6ac33c4ddc63e51486738ca8e5))
* **upstreams:** revalidate saved-reset redemption claims ([bdd9942](https://github.com/icoretech/codex-pooler/commit/bdd9942471e2805b321b4701b69c1664280dc69a))

## [0.4.8](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.4.7...codex-pooler-v0.4.8) (2026-06-30)


### Bug Fixes

* **upstreams:** distinguish upstream credentials by subject ([fffd246](https://github.com/icoretech/codex-pooler/commit/fffd246dbf9df1719ba9ad0fb488f4203bd13dd2))

## [0.4.7](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.4.6...codex-pooler-v0.4.7) (2026-06-29)


### Features

* expose skills usage metadata on codex models ([b12f84c](https://github.com/icoretech/codex-pooler/commit/b12f84c12a5393f436a624b755f75ace607a39ad))
* **settings:** add websocket idle timeout setting ([367c02e](https://github.com/icoretech/codex-pooler/commit/367c02ed488c3ee4b2720fb8fbe27412197cec49))


### Bug Fixes

* **gateway:** persist safe public responses stream summaries ([50d786c](https://github.com/icoretech/codex-pooler/commit/50d786c5554bc9f91b68e53ae6ba197ac2dda75c))
* **observability:** classify websocket pre-reservation closes ([3551fd5](https://github.com/icoretech/codex-pooler/commit/3551fd50ddc257721b9e82f874a80266c7195a23))
* **websocket:** apply bounded idle and message limits ([a728516](https://github.com/icoretech/codex-pooler/commit/a72851653557367fec714ce16d7e532e24f47338))
* **websocket:** size inbound frames from ingress body limit ([3097f5c](https://github.com/icoretech/codex-pooler/commit/3097f5c6cf4628bdbae9e5e9d0109aef277e7f8a))

## [0.4.6](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.4.5...codex-pooler-v0.4.6) (2026-06-29)


### Features

* **admin:** add saved reset bank panel to upstream cards ([d8c3474](https://github.com/icoretech/codex-pooler/commit/d8c347414ec288d74339bd8d548f42bf98eb1ba0))
* **admin:** add upstream pool lanes ([243fcc0](https://github.com/icoretech/codex-pooler/commit/243fcc0e8a612e4fc229d6c2451e3de8c30ee87d))
* **admin:** move banked reset meter into quota panel ([445e0fa](https://github.com/icoretech/codex-pooler/commit/445e0fa040ca9d4d929bf1a5e2474ab5c3d22799))
* **admin:** refine saved reset dialogs and docs links ([a15aac3](https://github.com/icoretech/codex-pooler/commit/a15aac33a900bb61d3acd1b5534408ffa287d87c))
* **upstreams:** track saved reset first-seen metadata ([6f59228](https://github.com/icoretech/codex-pooler/commit/6f5922863b9fb2997ac808bd93e74fc4ca415c8c))


### Bug Fixes

* **admin:** show pointer cursor on pools footer trigger ([6fffaa5](https://github.com/icoretech/codex-pooler/commit/6fffaa53bd0c097d3fb7687f98a6cdca36ed022b))
* **admin:** show upstream card issue borders without shadows ([f070320](https://github.com/icoretech/codex-pooler/commit/f0703204236860ef387c5928a3769550287df959))
* **upstreams:** fall back past HTML usage auth pages ([082bdda](https://github.com/icoretech/codex-pooler/commit/082bdda97db6f8eccfb53fbcdd0d95469ef29a3a))

## [0.4.5](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.4.4...codex-pooler-v0.4.5) (2026-06-28)


### Features

* support custom tool replay and cap upstream responses ([61ff473](https://github.com/icoretech/codex-pooler/commit/61ff4730ed25d0015e219dec76adb7b07f5450aa))


### Bug Fixes

* **alerts:** finalize webhook delivery exceptions ([c3d4328](https://github.com/icoretech/codex-pooler/commit/c3d43287943ae561aec922b21771fea72d7370b0))
* **catalog:** preserve active source assignments for seen models ([65831f5](https://github.com/icoretech/codex-pooler/commit/65831f58cddc1c0739e9cddcf40a12c6f6118950))
* **deps:** update dependency daisyui to ^5.6.3 ([#88](https://github.com/icoretech/codex-pooler/issues/88)) ([05ffd1b](https://github.com/icoretech/codex-pooler/commit/05ffd1bbd1eddda7438c37e1b98c00e93ba7a4d7))
* **deps:** update dependency starlight-page-actions to v0.6.2 ([#89](https://github.com/icoretech/codex-pooler/issues/89)) ([e4219ab](https://github.com/icoretech/codex-pooler/commit/e4219ab1d93b10b165df61a9a6593b67faaa8349))
* enqueue catalog sync after pool assignment changes ([2779388](https://github.com/icoretech/codex-pooler/commit/2779388e2d56d1c13197c373527b9944fe57723f))
* **gateway:** log unexpected quota refresh results ([c35306c](https://github.com/icoretech/codex-pooler/commit/c35306cea5e6432821c879286aa09b0db27c85f0))
* **gateway:** support attemptless turn completion ([1f38e41](https://github.com/icoretech/codex-pooler/commit/1f38e41efc92aa92c97c967fd8b3b42e22ee88e6))
* **openai-compat:** preserve nested response failure codes ([9aeb942](https://github.com/icoretech/codex-pooler/commit/9aeb942f2fe435fba9f383df10faa8dcf33883d3))
* preserve grep search evidence during compression ([3fc4c38](https://github.com/icoretech/codex-pooler/commit/3fc4c3814aedb0171bef12b30879d8eac1399889))
* raise non-stream upstream body cap to 64 MiB ([34a3092](https://github.com/icoretech/codex-pooler/commit/34a30925b65865aba226fd8bbcd95d982214d474))

## [0.4.4](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.4.3...codex-pooler-v0.4.4) (2026-06-27)


### Features

* **gateway:** coordinate websocket rollout drains ([5c990ad](https://github.com/icoretech/codex-pooler/commit/5c990ad10867467f2929e5f2ee8369a319e08433))


### Bug Fixes

* **accounting:** exclude unknown usage from consumption totals ([4d32260](https://github.com/icoretech/codex-pooler/commit/4d322607bf4e49572b74a665395635822d16c647))
* **accounting:** exclude unknown usage from reporting totals ([7e0a0a2](https://github.com/icoretech/codex-pooler/commit/7e0a0a2af5003a65f90332c3be3b6555151c672d))
* **deps:** update dependency daisyui to ^5.6.0 ([#85](https://github.com/icoretech/codex-pooler/issues/85)) ([724a4e6](https://github.com/icoretech/codex-pooler/commit/724a4e6ebbecb8df6f08cae8ab74b42775915c28))
* **gateway:** classify public sse transport interruptions ([e03967d](https://github.com/icoretech/codex-pooler/commit/e03967d3ed2894701a4e833cca58bf31d6d6ca72))
* **gateway:** reject websocket starts during rollout drain ([bf5b3a8](https://github.com/icoretech/codex-pooler/commit/bf5b3a82aa50dc519bd1b9f3d4f6d483d9f76332))
* **operations:** mark readiness unavailable during rollout drain ([59e0f34](https://github.com/icoretech/codex-pooler/commit/59e0f34e0f1f347a8cd04c1195668e2aa67aff23))
* **websocket:** finalize rollout drains as owner drained ([166879e](https://github.com/icoretech/codex-pooler/commit/166879efa6c47cc7786830d301c240f8cfb6f8ee))

## [0.4.3](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.4.2...codex-pooler-v0.4.3) (2026-06-25)


### Features

* **access:** allow ultra reasoning policy effort ([8eb58f5](https://github.com/icoretech/codex-pooler/commit/8eb58f5e14d3954e21b2af1c40fd3a814b40bda2))


### Bug Fixes

* accept indexed web search tool shape ([0f3f743](https://github.com/icoretech/codex-pooler/commit/0f3f74343de1638b9e2811a4fd35c0c6852414e1))
* avoid request log shared memory exhaustion ([13bda2e](https://github.com/icoretech/codex-pooler/commit/13bda2e7187b338d7957b7053667f501c83cb8c6))
* **gateway:** let websocket owner supervise upstream tasks ([67b3b6a](https://github.com/icoretech/codex-pooler/commit/67b3b6a3e5f0653906b6f05f35f2a292979fa89f))
* **gateway:** map backend ultra reasoning to max ([ba67b07](https://github.com/icoretech/codex-pooler/commit/ba67b07ec08162c4ad9ca25259c3036285468ff4))
* **gateway:** preserve oversized responses terminal failures ([a5d876e](https://github.com/icoretech/codex-pooler/commit/a5d876ef7077d2050751bb5d0100391e306aa5c7))
* **mailer:** preserve disabled SMTP probe result ([bb7f8d7](https://github.com/icoretech/codex-pooler/commit/bb7f8d753b12592c6b148ea3aa04c5aea24e017d))

## [0.4.2](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.4.1...codex-pooler-v0.4.2) (2026-06-24)


### Bug Fixes

* correct upstream popover placement ([cb16fe4](https://github.com/icoretech/codex-pooler/commit/cb16fe4062b4537dc05c04ca4a5a588b7859157c))
* **gateway:** accept trailing terminal response SSE events ([548909e](https://github.com/icoretech/codex-pooler/commit/548909e9c21717afd6ed4e98457829b98c5638bb))
* **gateway:** release health-neutral stream probes ([5a2d194](https://github.com/icoretech/codex-pooler/commit/5a2d1944d54cf2f5cdb691c93b9eb0ecffc6ac79))
* **gateway:** track oversized terminal response SSE events ([2a22bd7](https://github.com/icoretech/codex-pooler/commit/2a22bd78494a102c0c4e309195bd8c8ec0fcbb1e))
* **request-compression:** add bounded token accounting ([a70e0a4](https://github.com/icoretech/codex-pooler/commit/a70e0a4c54f2534381d1601b4c63a864ef29be75))
* **request-compression:** preserve grep search shape fidelity ([b31d704](https://github.com/icoretech/codex-pooler/commit/b31d7046d133e7229c2b4a29ab0106d7d5a7a249))
* **streaming:** keep overload failures health-neutral ([a3139ae](https://github.com/icoretech/codex-pooler/commit/a3139aeb3c6c098d3da614ca0cb483776543df88))

## [0.4.1](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.4.0...codex-pooler-v0.4.1) (2026-06-24)


### Features

* surface saved reset expiration metadata ([74c86b2](https://github.com/icoretech/codex-pooler/commit/74c86b248ed16b14327c08ce18ffebf791b8a0e3))


### Bug Fixes

* **gateway:** emit terminal responses failure on stream interruption ([4fcd699](https://github.com/icoretech/codex-pooler/commit/4fcd6999dc3441e577b89a57418722be2c75cc86))
* **gateway:** guard log output compression failure details ([815fd60](https://github.com/icoretech/codex-pooler/commit/815fd6054777c2b35b6ec2c71697bacfb6481c90))
* **gateway:** keep interrupted SSE streams health-neutral ([68821c3](https://github.com/icoretech/codex-pooler/commit/68821c3732cea474a6bc01d10580b82e69e63ddb))
* **gateway:** release neutral stream circuit probes ([7a9e282](https://github.com/icoretech/codex-pooler/commit/7a9e282132be4dd2936f39c4b07eee3cac3d57e0))
* **openai:** preserve codex turn metadata passthrough ([4830676](https://github.com/icoretech/codex-pooler/commit/483067669c759a303a838aa693a8d2b947daee1d))
* recover stale saved reset redemptions ([b19bf8f](https://github.com/icoretech/codex-pooler/commit/b19bf8f6ab4d6908c64b9474950d2acced70a9b1))
* redeem expiring saved resets ([4c83ae7](https://github.com/icoretech/codex-pooler/commit/4c83ae77c49fdaa562d32e5533740b85be200f8f))
* remove duplicate saved reset expiration banner ([6cb0f03](https://github.com/icoretech/codex-pooler/commit/6cb0f03af4a76c217fc91aa749b91df3d6896d90))


### Miscellaneous Chores

* release 0.4.1 ([4c1873f](https://github.com/icoretech/codex-pooler/commit/4c1873f9d994c191d161f58d2ed04114859ef2d6))

## [0.4.0](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.3.1...codex-pooler-v0.4.0) (2026-06-23)


### Features

* add Codex saved reset management ([1c50100](https://github.com/icoretech/codex-pooler/commit/1c50100691a8a4cd6f69acc629ff1e8eff3b6887))
* allow max reasoning effort policies ([421ceb7](https://github.com/icoretech/codex-pooler/commit/421ceb747d068fa7c5a5a3c19d0b32afbcbbe9d8))


### Bug Fixes

* advertise effective model context windows ([9e365c0](https://github.com/icoretech/codex-pooler/commit/9e365c0e611e3b298a3e82df26eab1819eb17f26))
* translate OMP function call replay statuses ([8cfd22e](https://github.com/icoretech/codex-pooler/commit/8cfd22e10ca2f6de37160b0a10efd8523a61c679))

## [0.3.1](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.3.0...codex-pooler-v0.3.1) (2026-06-22)


### Bug Fixes

* expose model context length in OpenAI catalog ([f31f0e9](https://github.com/icoretech/codex-pooler/commit/f31f0e996a6f306fdc1d498ef32c86c76c7faff8))

## [0.3.0](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.2.1...codex-pooler-v0.3.0) (2026-06-21)


### Features

* accept codex responses web search flags ([0c42bd3](https://github.com/icoretech/codex-pooler/commit/0c42bd3fb1e3deee3b8a063b6c35a5ea29378679))
* **admin:** inspect request log attempt diagnostics ([8f970ec](https://github.com/icoretech/codex-pooler/commit/8f970ec1eae0b731cd8744757152c29787f0fd8d))


### Bug Fixes

* **admin:** deduplicate upstream stats rows ([aab6f80](https://github.com/icoretech/codex-pooler/commit/aab6f80b094b93f0a492a9276e0d6e4b80dd58c2))
* **deps:** update dependency apexcharts to ^5.15.2 ([#72](https://github.com/icoretech/codex-pooler/issues/72)) ([d4c1bbc](https://github.com/icoretech/codex-pooler/commit/d4c1bbc324d91f476de64a5fb1a0c51d95a8b162))
* **gateway:** persist http transport failure diagnostics ([bc1e52d](https://github.com/icoretech/codex-pooler/commit/bc1e52d0507b9a80e4b27d372b5f7ee91cad2c81))
* preserve response incomplete terminal semantics ([51afd75](https://github.com/icoretech/codex-pooler/commit/51afd75ecb77bef8167fadb9f010daea1b2cda59))
* protect exact tool outputs during compression ([3c062c2](https://github.com/icoretech/codex-pooler/commit/3c062c2d504ce27d27fb119f83959d5b68ed2a1b))
* **upstreams:** reuse fresh quota evidence for transient reconciliation probes ([e1cbac8](https://github.com/icoretech/codex-pooler/commit/e1cbac8172e3f159d0df459abffa48baefcc1daf))

## [0.2.1](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.2.0...codex-pooler-v0.2.1) (2026-06-18)


### Features

* **accounting:** show compression processing throughput ([8bbb291](https://github.com/icoretech/codex-pooler/commit/8bbb2915a4a7d04966ed8a6e71d2e8034745a1fc))


### Bug Fixes

* **admin:** align upstream routing readiness with account lifecycle ([517c0ab](https://github.com/icoretech/codex-pooler/commit/517c0abb1037222590169a217cdfc8635baf941c))
* **deps:** update astro monorepo to v6.4.8 ([d81bf2c](https://github.com/icoretech/codex-pooler/commit/d81bf2cdb0e13aa301f1192dde909597250dac46))
* refine admin stats chart and table UI ([8b54759](https://github.com/icoretech/codex-pooler/commit/8b54759b4cff771fb78cc3f0cf6ffece36592dc7))
* reject OpenAI Responses remote MCP tools ([1630301](https://github.com/icoretech/codex-pooler/commit/16303012e564bc8c6d3ca41b57b179ab001025c5))
* **runtime:** strip store from compact bridge ([78343c3](https://github.com/icoretech/codex-pooler/commit/78343c33f71a8f395e457875e7669995a8adfb73))
* **upstreams:** avoid token refresh loops on fresh usage probes ([9458784](https://github.com/icoretech/codex-pooler/commit/9458784ced656c67ce56c8d8dc1853614d016954))


### Reverts

* remove compression throughput display ([1fdda21](https://github.com/icoretech/codex-pooler/commit/1fdda21fb62dc09fb7ec12ad9eb4c870e23f3993))


### Miscellaneous Chores

* release 0.2.1 ([0a7023b](https://github.com/icoretech/codex-pooler/commit/0a7023b80efc79be07dac7aae47f855e76eefba3))

## [0.2.0](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.1.1...codex-pooler-v0.2.0) (2026-06-17)


### Features

* **compression:** handle minimal unified diffs ([f839b41](https://github.com/icoretech/codex-pooler/commit/f839b41bf6b9075ab9892fccd2b21e4ee225002f))
* **compression:** support grouped search output ([6ee8498](https://github.com/icoretech/codex-pooler/commit/6ee84985e5b0a6d1218aed54486ce7e3816ce351))
* **gateway:** lower non-strict function schemas ([a99be2e](https://github.com/icoretech/codex-pooler/commit/a99be2e43c0ae316a411430b09d9117f836bbe5f))
* **runtime:** proxy reset-credit consume routes ([b3a37fd](https://github.com/icoretech/codex-pooler/commit/b3a37fdd8743e36346153cb1bbf046b6466ca825))
* **v1:** normalize responses reasoning context ([554d048](https://github.com/icoretech/codex-pooler/commit/554d0488f193da2ba41943ae468010d8a1f36b49))


### Bug Fixes

* **access:** reject invalid invite list scopes ([192c6cb](https://github.com/icoretech/codex-pooler/commit/192c6cb13e4b3036817291a4c5534e2f03e987d5))
* **accounting:** honor unavailable pricing buckets ([32e2a45](https://github.com/icoretech/codex-pooler/commit/32e2a45d1c1217849255210fae7fe7c6006ae983))
* **accounting:** keep legacy proxy-control log redaction ([7fb6004](https://github.com/icoretech/codex-pooler/commit/7fb6004850d297c4cf4d5466b0bf6ca56d0e64cf))
* **accounting:** reject pruned runtime endpoints for new requests ([c6e3977](https://github.com/icoretech/codex-pooler/commit/c6e3977659108658bc9b642557012eae2fa31a48))
* **accounting:** remove analytics forwarding metadata residue ([770f6f0](https://github.com/icoretech/codex-pooler/commit/770f6f0cfcb5fb3dee0151bd8e7d2fae208f28c0))
* **gateway:** strip encrypted websocket agent messages ([4bbd303](https://github.com/icoretech/codex-pooler/commit/4bbd30397be180c9fabc6afab3cc83a0c3038401))
* make settings reads safe before cache start ([ae53325](https://github.com/icoretech/codex-pooler/commit/ae53325cf8a21b4e5f484b8040f64d82f80174e6))
* **mcp:** validate metadata lookup arguments ([9c309e6](https://github.com/icoretech/codex-pooler/commit/9c309e6623f9543c9cf936cace715088898cb763))
* **pools:** remove control-plane analytics setting ([1c042d4](https://github.com/icoretech/codex-pooler/commit/1c042d4d9a9bdcd54cb0a1f4af8d90f9ff2d56dd))
* preserve request option values on invalid updates ([f62d169](https://github.com/icoretech/codex-pooler/commit/f62d1693858bfa862e2d1a87c2f338f9b59f42b8))
* **runtime:** remove backend control-plane proxy routes ([72d911c](https://github.com/icoretech/codex-pooler/commit/72d911cb29ba331cc64916cc28985d409bfb41f5))
* **runtime:** remove reset-credit consume proxy routes ([b9085a7](https://github.com/icoretech/codex-pooler/commit/b9085a7691367f2f306a07004bb2ff8949049042))
* **runtime:** return pruned helper routes before parsing ([85797ae](https://github.com/icoretech/codex-pooler/commit/85797ae11591c9f291a35cc701a2ed97fd1fe337))

## [0.1.1](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.1.0...codex-pooler-v0.1.1) (2026-06-16)


### Bug Fixes

* **accounting:** infer pricing for suffixed model ids ([1ecc85f](https://github.com/icoretech/codex-pooler/commit/1ecc85ff4ea3139cbc72b7ea8e4e1c58f99312b5))
* **accounting:** preserve sanitized failure reasons ([3b19a26](https://github.com/icoretech/codex-pooler/commit/3b19a26d825ef8e4951f148e5681282deb87d74b))
* **admin:** type request log user agent icons ([d49c42b](https://github.com/icoretech/codex-pooler/commit/d49c42b031602e06f56b3884e295f26379a27c84))
* **api:** route audio through gateway adapter ([2c27ab8](https://github.com/icoretech/codex-pooler/commit/2c27ab8584b534fef8b4bf63467d474af02548cb))
* **deps:** update astro monorepo to v6.4.7 ([b40fde2](https://github.com/icoretech/codex-pooler/commit/b40fde2072fb154712e5834b29f02dea3f718a5e))
* **gateway:** preserve responses item metadata ([9358914](https://github.com/icoretech/codex-pooler/commit/9358914fdbdff0da135fc65c2173d262dffd3de4))

## [0.1.0](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.0.15...codex-pooler-v0.1.0) (2026-06-15)


### Features

* **gateway:** add request compression ([689a73f](https://github.com/icoretech/codex-pooler/commit/689a73ff2bec9b7a7a7ef49d7edc8333f35c6bf8))
* **gateway:** expand request compression coverage ([765d8a7](https://github.com/icoretech/codex-pooler/commit/765d8a7e0832b6ef0b4c9be267526d446919beb4))

## [0.0.15](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.0.14...codex-pooler-v0.0.15) (2026-06-14)


### Bug Fixes

* **gateway:** recover retained response tiers ([0a6d950](https://github.com/icoretech/codex-pooler/commit/0a6d950dd85860de28fe13a443836111d22e15cf))
* **gateway:** settle terminal response usage ([cfb636d](https://github.com/icoretech/codex-pooler/commit/cfb636d1798291acf34d0c540d317d2196a91526))

## [0.0.14](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.0.13...codex-pooler-v0.0.14) (2026-06-14)


### Features

* **admin:** add project resource menu ([8d6864d](https://github.com/icoretech/codex-pooler/commit/8d6864dfe0ee54e17631b7bae595b58038ae6743))


### Bug Fixes

* **admin:** keep worker card actions aligned ([0afc383](https://github.com/icoretech/codex-pooler/commit/0afc383e264eb3d5afcf272c4742df8d71a7eae6))
* **admin:** report settled usage costs ([3378d49](https://github.com/icoretech/codex-pooler/commit/3378d4980d06b2320113fb5b8c0190ce0a78de05))
* **dev:** isolate local postgres env ([ac65437](https://github.com/icoretech/codex-pooler/commit/ac65437af2f24a40635e2790533c944893c16602))

## [0.0.13](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.0.12...codex-pooler-v0.0.13) (2026-06-13)


### Bug Fixes

* **admin:** map more request log user agents ([5d6195f](https://github.com/icoretech/codex-pooler/commit/5d6195f4bfec2066541729e40382e7e6398b5513))
* **gateway:** hash turn-state session keys ([29f94d7](https://github.com/icoretech/codex-pooler/commit/29f94d7a8a7a841a580fdda4c1a75fd4a5a9c666))
* **gateway:** support Kilo chat completion streams ([16f21be](https://github.com/icoretech/codex-pooler/commit/16f21be263291511b4eb88d12a222b37eda541dd))
* **openai:** accept OMP completed tool replay ([e6d3980](https://github.com/icoretech/codex-pooler/commit/e6d3980bc6382310279ecb9ca72bf61c58e74d18))
* **payloads:** extract backend turn-state metadata ([99e471d](https://github.com/icoretech/codex-pooler/commit/99e471dcb24237b172ab466c5c81d0e1679d2c38))
* **runtime:** relay backend turn-state headers ([a787f75](https://github.com/icoretech/codex-pooler/commit/a787f75a74134461d64226d32665cd56f76dd9a1))
* **websocket:** persist frame turn-state continuity ([323e4e5](https://github.com/icoretech/codex-pooler/commit/323e4e5f6cb5a05b2af7f06f51bc70eddf627b29))
* **websocket:** retarget owners by frame turn-state ([18eb85d](https://github.com/icoretech/codex-pooler/commit/18eb85d232cf7843164628efe2b968762c95b4e6))

## [0.0.12](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.0.11...codex-pooler-v0.0.12) (2026-06-13)


### Features

* **admin:** add pool traffic window selector ([215a2d3](https://github.com/icoretech/codex-pooler/commit/215a2d37ae65c9133cfad53481fdecea894fc648))
* **admin:** add shared usage formatters ([4626780](https://github.com/icoretech/codex-pooler/commit/462678095d600b3463356204e0743776137f85e4))
* **admin:** add stats token cost chart ([faa092f](https://github.com/icoretech/codex-pooler/commit/faa092f981d5836fe8b1b04b04f491c2f30b81d8))


### Bug Fixes

* **admin:** align job card headers ([c8339cc](https://github.com/icoretech/codex-pooler/commit/c8339cc5e86befc52e117a6d63ccce5efb485872))
* **admin:** contain filter dropdowns and dialogs ([5f002fd](https://github.com/icoretech/codex-pooler/commit/5f002fd90561410f856e449d080c4b17a5d10070))
* **admin:** hide pool card chart legends ([6dba819](https://github.com/icoretech/codex-pooler/commit/6dba8196e88c818250ca05e49a1d9707522c7961))
* **admin:** hide relink on usable upstream accounts ([a679c40](https://github.com/icoretech/codex-pooler/commit/a679c40a037d11cb5d36be06da137ff26db267f3))
* **admin:** refine pool traffic cards ([f396515](https://github.com/icoretech/codex-pooler/commit/f396515372313d64fa7202e555b78625cbf0f119))
* **admin:** remove unreachable pool formatter clause ([8e4dce5](https://github.com/icoretech/codex-pooler/commit/8e4dce596d2bd264d347662926d05c5f12be87c1))
* **admin:** show pool throughput and cost metrics ([266e520](https://github.com/icoretech/codex-pooler/commit/266e520e8a11225e94b96735950c0099f3e8ca95))
* **deps:** update dependency apexcharts to ^5.15.0 ([#22](https://github.com/icoretech/codex-pooler/issues/22)) ([91baed8](https://github.com/icoretech/codex-pooler/commit/91baed8130f811d509d14a99d72ddef4f92b9337))
* **dev:** isolate local postgres credentials ([28d997c](https://github.com/icoretech/codex-pooler/commit/28d997c6012038185b00add6fe860c31fc7b2860))
* **files:** validate upstream upload urls ([f625acf](https://github.com/icoretech/codex-pooler/commit/f625acf0092833326b7f78d7f4372a26708a2c34))
* **openai:** harden public compatibility responses ([644f20d](https://github.com/icoretech/codex-pooler/commit/644f20ddda56fea375f00890bf44458e5fc96c0b))
* **renovate:** avoid overlapping toolchain regexes ([4286010](https://github.com/icoretech/codex-pooler/commit/4286010f46916245ae6ecd038ea05537cff20d3e))
* **renovate:** keep elixir toolchain pins compatible ([262c203](https://github.com/icoretech/codex-pooler/commit/262c2038d59ba4c4a2828277907b261d48105619))
* **renovate:** pin mix artifact toolchain ([13c4290](https://github.com/icoretech/codex-pooler/commit/13c4290ec489394aab33372f5d6d50865220adab))
* **renovate:** restore otp-specific elixir pin ([abbb571](https://github.com/icoretech/codex-pooler/commit/abbb5714df348d5fc792444dc1b230b5c5e60541))
* **renovate:** use erlang prebuild constraint ([ea45bb9](https://github.com/icoretech/codex-pooler/commit/ea45bb98cd1e48df9ffd3c443c161ab250b3d42d))
* **renovate:** use installable mix artifact elixir ([4b4a478](https://github.com/icoretech/codex-pooler/commit/4b4a478edd711d33ddac15b9bd9bd87879216c2b))
* **runtime:** forward codex installation metadata ([3a332f5](https://github.com/icoretech/codex-pooler/commit/3a332f53dd4f3df5886ea7d3361133952b2e9a6c))

## [0.0.11](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.0.10...codex-pooler-v0.0.11) (2026-06-11)


### Features

* **admin:** add upstream account relink action ([843e188](https://github.com/icoretech/codex-pooler/commit/843e18827cb4792acdc48e1755290d13a8e87b8b))
* **docs:** clarify OAuth device-code setup ([0257377](https://github.com/icoretech/codex-pooler/commit/025737761d5f7c68eb1630029016731735a1671f))
* **upstreams:** add OpenAI OAuth linking ([a317aa2](https://github.com/icoretech/codex-pooler/commit/a317aa27f7ce6df097e44881599b661e799c2242))


### Bug Fixes

* **access:** preserve skipped invite email result ([a3793db](https://github.com/icoretech/codex-pooler/commit/a3793db3c9e4b58f934eb6ba66844fcb72a92d6c))
* **accounting:** rebuild daily rollups set-wise ([a8baf70](https://github.com/icoretech/codex-pooler/commit/a8baf70e659ed48cb0e42e45a1ffe2e883e2f459))
* **admin:** add invite dialog backdrop id ([d963688](https://github.com/icoretech/codex-pooler/commit/d9636880b61865497f53b4f218a21c2a0f6e83b1))
* **admin:** clear recovered reconciliation alerts ([de16639](https://github.com/icoretech/codex-pooler/commit/de16639a3a2eee2d9ce4711455bc4f09d8f6b926))
* **admin:** point Pool dialog docs to pools guide ([eb5d8b7](https://github.com/icoretech/codex-pooler/commit/eb5d8b7e1a575eacb10dd1f036f2365a310978df))
* **admin:** recheck settings capability on save ([6a7c6b3](https://github.com/icoretech/codex-pooler/commit/6a7c6b33bcea43b716a0d4b1af7a4f0b3c82a6ee))
* **admin:** rename upstream OAuth action ([911c4c2](https://github.com/icoretech/codex-pooler/commit/911c4c2b30a36450b669b09f9d790c27ff4753df))
* **admin:** render percent-only quota bars ([b1e8a86](https://github.com/icoretech/codex-pooler/commit/b1e8a863292b554d3383f028325ebed4a38a2d43))
* **admin:** surface unavailable API key models ([aa04a8f](https://github.com/icoretech/codex-pooler/commit/aa04a8f29bc952b1ccb9d7e34a4b1c0bcaf7f252))
* dedupe reconciliation and classify hard-pinned recovery ([6383dcc](https://github.com/icoretech/codex-pooler/commit/6383dccf79696108c1eb6c291432fb49c1d59601))
* **deps:** update astro monorepo to v6.4.5 ([7260919](https://github.com/icoretech/codex-pooler/commit/7260919655c01b0a247c431359bb31fca43c48c1))
* **deps:** update dependency @astrojs/starlight to v0.40.0 ([#43](https://github.com/icoretech/codex-pooler/issues/43)) ([511ce7a](https://github.com/icoretech/codex-pooler/commit/511ce7ac758a1bf7238ffca607cc26000107d48e))
* **deps:** update dependency starlight-page-actions to v0.6.1 ([#42](https://github.com/icoretech/codex-pooler/issues/42)) ([c1b2592](https://github.com/icoretech/codex-pooler/commit/c1b259234f08f2db0cbcc6f41663bf28d8f69cfc))
* **deps:** update docs dependency group ([54be3c5](https://github.com/icoretech/codex-pooler/commit/54be3c5d1734ddc9b63d836b636b2045eae05433))
* **jobs:** schedule token refresh recovery ([147d7e7](https://github.com/icoretech/codex-pooler/commit/147d7e70becfdb03b0ae76532f792ba9e8e2abd4))
* **runtime:** match current Codex compatibility behavior ([29fe692](https://github.com/icoretech/codex-pooler/commit/29fe69265cb952f9b100114f9e09f422770373c7))

## [0.0.10](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.0.9...codex-pooler-v0.0.10) (2026-06-10)


### Bug Fixes

* **clients:** remove Roo Code references ([5ecee96](https://github.com/icoretech/codex-pooler/commit/5ecee96ab47d3c698d50b1ec6388c2d5cea7b398))
* **transports:** classify safe transport failures ([8e9475a](https://github.com/icoretech/codex-pooler/commit/8e9475a47f7279c0c8f58a49ef7c54109671a56c))
* **websocket:** persist upstream transport diagnostics ([812dcef](https://github.com/icoretech/codex-pooler/commit/812dcefe2c8609370335de514e2d7a83f835c95d))
* **websocket:** preserve owner transport diagnostics ([0484d47](https://github.com/icoretech/codex-pooler/commit/0484d470df9e4cab26ce9e1ea47349f93b84dcb1))

## [0.0.9](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.0.8...codex-pooler-v0.0.9) (2026-06-10)


### Bug Fixes

* **chat:** backfill streamed tool call ids ([f1ce55b](https://github.com/icoretech/codex-pooler/commit/f1ce55bdbd228c8f45f03c92d0b66d9c5426dd18))
* **chat:** translate Cline tool continuations ([8a7063e](https://github.com/icoretech/codex-pooler/commit/8a7063e5d6cdaf0d4bcaf5893e0a8ea52d784635))
* **dev:** pin postgres healthcheck database ([0d4f901](https://github.com/icoretech/codex-pooler/commit/0d4f901d00f1d9b342d97620c9790970ef6bf920))
* **gateway:** suppress keepalives during partial public SSE ([5c14a59](https://github.com/icoretech/codex-pooler/commit/5c14a59f83890b4951be6be02172f97196864c25))
* **responses:** backfill streamed output item ids ([17870cd](https://github.com/icoretech/codex-pooler/commit/17870cda1754af97f7868e77bcbaa2c39ab7bdcd))

## [0.0.8](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.0.7...codex-pooler-v0.0.8) (2026-06-09)


### Bug Fixes

* **gateway:** drop encrypted websocket agent messages ([096e394](https://github.com/icoretech/codex-pooler/commit/096e394e818a8303fb4a27dc1eda4cd03bf520fa))
* **responses:** backfill empty chat completion output ([18a29be](https://github.com/icoretech/codex-pooler/commit/18a29beeb8177d6dad929d7fa19cf49042c00a15))

## [0.0.7](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.0.6...codex-pooler-v0.0.7) (2026-06-09)


### Bug Fixes

* **gateway:** drop encrypted tool schema markers ([39f96fc](https://github.com/icoretech/codex-pooler/commit/39f96fc222adfe5c98cb0ffa98eaf95e06678053))
* **gateway:** keep refreshing identities route-visible ([74eaec1](https://github.com/icoretech/codex-pooler/commit/74eaec139ba19ccb2c81b19e2bef265efee656c7))
* **gateway:** prefer Codex window continuity ([6441e83](https://github.com/icoretech/codex-pooler/commit/6441e83dc2396bc40b48550e289fe45d03ed3b74))
* **responses:** accept namespace function tools ([d100796](https://github.com/icoretech/codex-pooler/commit/d100796f879f40df8edf215e98de6c66bc6513d3))

## [0.0.6](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.0.5...codex-pooler-v0.0.6) (2026-06-09)


### Bug Fixes

* **responses:** accept Hermes assistant replay status ([dae80c4](https://github.com/icoretech/codex-pooler/commit/dae80c4c14f2df8738ea8922ff3059f5dd95f20c))
* **responses:** accept OpenClaw replay shapes ([02c1812](https://github.com/icoretech/codex-pooler/commit/02c18121a9efb5f3991fc49a5e329263b5606d95))

## [0.0.5](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.0.4...codex-pooler-v0.0.5) (2026-06-09)


### Bug Fixes

* **admin:** debounce upstreams event reloads ([f5af1ed](https://github.com/icoretech/codex-pooler/commit/f5af1ed77f3d5745b9ddee3e52868f853aaac9e3))
* **responses:** accept Hermes assistant tool replays ([fb5a6bb](https://github.com/icoretech/codex-pooler/commit/fb5a6bb7860a7573f69f0e5a5b8962106c744453))
* **responses:** accept Hermes reasoning replays ([274c256](https://github.com/icoretech/codex-pooler/commit/274c2561c261697bc7e87c7415476ebb9cab23d0))
* **responses:** accept Hermes tool continuations ([9b263aa](https://github.com/icoretech/codex-pooler/commit/9b263aa6a7bdbb7cbbe0eda6907731caed8e6e63))

## [0.0.4](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.0.3...codex-pooler-v0.0.4) (2026-06-08)


### Bug Fixes

* **accounting:** restore request log sse costs ([924df6d](https://github.com/icoretech/codex-pooler/commit/924df6dd5de10fbb21cf7ebd6e3fdff94dcdddc4))
* **deps:** update dependency bandit to 1.12.0 ([abf5288](https://github.com/icoretech/codex-pooler/commit/abf52881f72d6e35a77b1c66c772bd45f7735999))
* **deps:** update dependency daisyui to ^5.5.23 ([#28](https://github.com/icoretech/codex-pooler/issues/28)) ([cdf21cc](https://github.com/icoretech/codex-pooler/commit/cdf21cc4a1b6d0931e93b80e838c6c5d4d1fa5b1))


### Performance Improvements

* **accounting:** project request log facts ([ed5271e](https://github.com/icoretech/codex-pooler/commit/ed5271e096a5e9f6679e44051b7e1e1de28b0291))

## [0.0.3](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.0.2...codex-pooler-v0.0.3) (2026-06-07)


### Bug Fixes

* **accounting:** make attempt inserts idempotent ([5edbc20](https://github.com/icoretech/codex-pooler/commit/5edbc20313adcae2da10e6aee0450e8458b01960))
* **admin:** hide legacy workspace context ([d335406](https://github.com/icoretech/codex-pooler/commit/d3354068b8ca21c062fb69f1c1aeddc6c949d5d9))
* **admin:** make upstream invite the primary action ([f793320](https://github.com/icoretech/codex-pooler/commit/f793320edddec2f2f91ec64559632b89d467544e))
* **quota:** recognize monthly-only account primary windows ([7fb5643](https://github.com/icoretech/codex-pooler/commit/7fb5643e6ee6b111ecf0de7030129e9d0de5870c))
* remove stats upstream quota column ([78bb465](https://github.com/icoretech/codex-pooler/commit/78bb4654e790d5b99091cd5a511da90774a09ca2))
* **websocket:** align owner forwarding with alias continuity ([bd9fb8c](https://github.com/icoretech/codex-pooler/commit/bd9fb8c5a6ef6f7562c5be54c999649e5951d777))
* **websocket:** order tool continuations after processed frames ([cc7c988](https://github.com/icoretech/codex-pooler/commit/cc7c988541f7da341ff1c8c2fb779148b9fb1f67))
* **websocket:** resolve frame previous response aliases ([065b6f3](https://github.com/icoretech/codex-pooler/commit/065b6f36100b505709186ceae3703a9ba896be86))
* **websocket:** suppress replayed owner reconnects ([3601e5a](https://github.com/icoretech/codex-pooler/commit/3601e5adb505fc727e227742e1bd54a4ae5be213))
* **websocket:** treat owner busy as transient ([458685a](https://github.com/icoretech/codex-pooler/commit/458685a8964d3e51cf4ee3981a28c7de3be49449))

## [0.0.2](https://github.com/icoretech/codex-pooler/compare/codex-pooler-v0.0.1...codex-pooler-v0.0.2) (2026-06-07)


### Features

* **docs:** add Plausible analytics ([6786b7a](https://github.com/icoretech/codex-pooler/commit/6786b7a48f4bd1507016b98765d870d6fa4d4f8c))


### Bug Fixes

* **admin:** align pool visibility counts ([487088d](https://github.com/icoretech/codex-pooler/commit/487088d1adb8baf99301150d976b7a7f9294ad21))
* **deps:** replace tzdata with zoneinfo ([8757704](https://github.com/icoretech/codex-pooler/commit/87577049be112a0ae31f355d1a168a2e354195d8))
* **dev:** force compile before make dev startup ([b112165](https://github.com/icoretech/codex-pooler/commit/b112165a7beecf06110c4872beeaa8d684815cfb))
* **release:** normalize component release tags ([00feabb](https://github.com/icoretech/codex-pooler/commit/00feabbcf7a3aebc0ac269c82514d20dee8a836b))

## 0.0.1 (2026-06-06)


### Features

* **access:** scope runtime credentials by pool ([6f1ab99](https://github.com/icoretech/codex-pooler/commit/6f1ab999e6d1f826ba96dca147cacfedc7dd68e5))
* **accounts:** expose scoped operator assignments ([ce6b284](https://github.com/icoretech/codex-pooler/commit/ce6b284c9db5fda4f3d82f980b7035a82d885756))
* **accounts:** manage operator pool access ([3f7f542](https://github.com/icoretech/codex-pooler/commit/3f7f54290f4d94f9a477c0ff173a2ab77fce387b))
* add production memory telemetry ([097d0c3](https://github.com/icoretech/codex-pooler/commit/097d0c32b8dee945cd1ae5dea5ecb43770cbab8a))
* add system jobs enqueue actions ([3821cbe](https://github.com/icoretech/codex-pooler/commit/3821cbe9f244ab5943be726425977ab050d3d943))
* add upstream capacity slot ([3223ff4](https://github.com/icoretech/codex-pooler/commit/3223ff4e41f1f1a02270a43bc68867984a09cba7))
* **admin:** add alert form helpers ([bc2d1be](https://github.com/icoretech/codex-pooler/commit/bc2d1be17d63642ccbc96dd78c3fa6a52f2a0896))
* **admin:** add alert incident read model ([c9c82ef](https://github.com/icoretech/codex-pooler/commit/c9c82efe358d208199eb3fe5993fd2872a832efe))
* **admin:** add alert notification anchors ([be2bdc1](https://github.com/icoretech/codex-pooler/commit/be2bdc108acf6fd45461e0542f57d408f33d1907))
* **admin:** add alerts management liveview ([166df8a](https://github.com/icoretech/codex-pooler/commit/166df8a6653ceff7fe7d7cb6d7348cebfb8c7548))
* **admin:** add alerts route navigation ([bc6a2da](https://github.com/icoretech/codex-pooler/commit/bc6a2dac251f74e9c7a13bdb9a9eb95446f9e5ec))
* **admin:** add jobs operations explorer ([1085236](https://github.com/icoretech/codex-pooler/commit/1085236a280e4cdaf907363541a98b12a1ee6f5a))
* **admin:** add notification read model ([7927edf](https://github.com/icoretech/codex-pooler/commit/7927edfa2b2ef6320a243be6bf057b7c8c70fbf0))
* **admin:** add pool traffic histograms ([3e9e1db](https://github.com/icoretech/codex-pooler/commit/3e9e1db6deebaff06c9fe780bdfc8ae4eb6b32f2))
* **admin:** add stats dashboard observability ([0c219f0](https://github.com/icoretech/codex-pooler/commit/0c219f03560fc2678fcdd958ca6c20b30a1fbbca))
* **admin:** add upstream account filters ([3178e41](https://github.com/icoretech/codex-pooler/commit/3178e4111c4d0e143f66755c44974e7b20096f15))
* **admin:** add upstream account recovery actions ([5f3ce2d](https://github.com/icoretech/codex-pooler/commit/5f3ce2dd3f493f8f51a0e0602baefdb980b37dbc))
* **admin:** add upstream account rename dialog ([fe49c32](https://github.com/icoretech/codex-pooler/commit/fe49c327e6b4196781244e20ec6e752d5f7cc5ce))
* **admin:** add upstream cockpit page ([738abbe](https://github.com/icoretech/codex-pooler/commit/738abbe1948c826a042078543a44258f15b33d34))
* **admin:** add upstream cockpit read model ([20c5648](https://github.com/icoretech/codex-pooler/commit/20c56489a162058141fcb917398cfebf55572b53))
* **admin:** align upstream scoped filters ([bf57554](https://github.com/icoretech/codex-pooler/commit/bf575541931d43da45d0bce11fe7578144fa1197))
* **admin:** classify request log user agents ([2f4fc17](https://github.com/icoretech/codex-pooler/commit/2f4fc17f083ce84b2f2d80b1c056c8a1b7fd21ad))
* **admin:** combine stats traffic chart ([b4a96a7](https://github.com/icoretech/codex-pooler/commit/b4a96a7aa6debb53bf9642cf897a30eea3a6694b))
* **admin:** derive upstream quota readiness from windows ([5895747](https://github.com/icoretech/codex-pooler/commit/5895747d82bae56c5b6b9718ecd4da4789056157))
* **admin:** expose prompt cache locality toggle ([8698553](https://github.com/icoretech/codex-pooler/commit/86985533be4e14bc23d5b40b3e9062666611cb64))
* **admin:** expose upstream codex user-agent setting ([e2843ab](https://github.com/icoretech/codex-pooler/commit/e2843ab8dde81bab78bd2c3b7140f4290d4bc8f2))
* **admin:** gate owner-only settings UI ([024ff67](https://github.com/icoretech/codex-pooler/commit/024ff6760abd8d11531bceba6430a505f4f3f08d))
* **admin:** manage operator pool assignments ([cb55d2e](https://github.com/icoretech/codex-pooler/commit/cb55d2e68645cc85c6184c6c039f62119c2e50e2))
* **admin:** mount notification hooks ([88e34e7](https://github.com/icoretech/codex-pooler/commit/88e34e71c5e92662c076197a254f51080d126d2a))
* **admin:** prefill invite recovery dialog ([7b77228](https://github.com/icoretech/codex-pooler/commit/7b77228ebcda0ca19e8cab9a01da8cfb296d97db))
* **admin:** refine request log filters ([e9c6684](https://github.com/icoretech/codex-pooler/commit/e9c6684b47387509c53e6201116349217de23a29))
* **admin:** refine system jobs UI ([d758233](https://github.com/icoretech/codex-pooler/commit/d7582332ec8ab6b57f4eabb746a828b9e629acd4))
* **admin:** render alert notification bell ([59ef49b](https://github.com/icoretech/codex-pooler/commit/59ef49bd639d8b95a8e10aaaaa6e0529b0ef5397))
* **admin:** render pool quota pressure charts ([0617c76](https://github.com/icoretech/codex-pooler/commit/0617c766bb9a52fc66ca22e240b4ec21fbebeba4))
* **admin:** render scoped dashboard stats ([561244d](https://github.com/icoretech/codex-pooler/commit/561244dfdb4ac2a7dadf122534114966c54b8ddd))
* **admin:** route owners to global surfaces ([aaed91b](https://github.com/icoretech/codex-pooler/commit/aaed91b54603eca9b3ddf916ae414b106640cc7e))
* **admin:** scope API key management UI ([6339929](https://github.com/icoretech/codex-pooler/commit/63399291595758643534522dbe563325e8471a57))
* **admin:** scope invite management UI ([9430b11](https://github.com/icoretech/codex-pooler/commit/9430b1176754c1e95734663fda9ce7d59e479ae8))
* **admin:** scope pool management UI ([bdda129](https://github.com/icoretech/codex-pooler/commit/bdda129d95a456bafbf1d821a90806c5be380a24))
* **admin:** scope request log filters ([bdc8575](https://github.com/icoretech/codex-pooler/commit/bdc857582dccbc1556867fe27822359d12a7a8b6))
* **admin:** scope stats read models ([b4d8fd4](https://github.com/icoretech/codex-pooler/commit/b4d8fd4c710882c2ea987ea8eb7adbdc8cfba47c))
* **admin:** show alert audit rows ([624519f](https://github.com/icoretech/codex-pooler/commit/624519f025f13479a8e1611921d8cc19c5b40d32))
* **admin:** show scoped job summaries ([f37dbb2](https://github.com/icoretech/codex-pooler/commit/f37dbb21005ff8af41b255e1e0fa92e151ab3c33))
* **admin:** show translated request origins ([f415524](https://github.com/icoretech/codex-pooler/commit/f415524a11e8e47c6fa9e9d380093c8f6df78e78))
* **admin:** support recovery action primitives ([b8d8bd4](https://github.com/icoretech/codex-pooler/commit/b8d8bd42d291902d742c20995b0d0818e63b3754))
* **admin:** support stacked mobile filter fields ([42ecdc8](https://github.com/icoretech/codex-pooler/commit/42ecdc89a29892d12c3b82856f8e31e646634366))
* **admin:** wire notifications on log pages ([5c562d9](https://github.com/icoretech/codex-pooler/commit/5c562d9384768fc305cf9042c0a785b034d5b1a2))
* **admin:** wire notifications on operator pages ([c3a13cc](https://github.com/icoretech/codex-pooler/commit/c3a13cc3a15413ede5c7a0a44aa16559d6406d47))
* **admin:** wire notifications on pool pages ([1904b0e](https://github.com/icoretech/codex-pooler/commit/1904b0eef4f9b9c141b2aa0702fb490f8c0ce843))
* **admin:** wire notifications on system pages ([1e2fb82](https://github.com/icoretech/codex-pooler/commit/1e2fb82ed2686d7180c6b6d36bff4684e5e4c0d3))
* **alerts:** add alert audit events ([518505e](https://github.com/icoretech/codex-pooler/commit/518505e531053ff510598475a299d077a36b5d00))
* **alerts:** add alert facade authorization ([4a17b58](https://github.com/icoretech/codex-pooler/commit/4a17b585dd5a1bc6a69042a3363ab657a0f2b8ff))
* **alerts:** add alert job scheduling ([6d3dcf2](https://github.com/icoretech/codex-pooler/commit/6d3dcf20fa94737ce244e42756d41f0445394a40))
* **alerts:** add alert storage schema ([34ef1ae](https://github.com/icoretech/codex-pooler/commit/34ef1aed35b2790d7b4d163ba82170920ced75f5))
* **alerts:** add channel endpoint contracts ([c295021](https://github.com/icoretech/codex-pooler/commit/c295021215882144e3261e3d6b55fd9ec9b4db18))
* **alerts:** add email delivery adapter ([3a6cd87](https://github.com/icoretech/codex-pooler/commit/3a6cd87f6da5024aedeee06cf8beebad23be4c13))
* **alerts:** add incident lifecycle ([a3aac3a](https://github.com/icoretech/codex-pooler/commit/a3aac3a6c233b3aec08927522af78acd354f25db))
* **alerts:** add incident receipt storage ([41569fc](https://github.com/icoretech/codex-pooler/commit/41569fcde79f0ed85182454b1e301103f0feab56))
* **alerts:** add notification events ([1def0bc](https://github.com/icoretech/codex-pooler/commit/1def0bca825c947801f50574dc251c457b95e308))
* **alerts:** add notification receipt actions ([2df7ff4](https://github.com/icoretech/codex-pooler/commit/2df7ff409d61e83ebd3c6018f5ec41e2989062a2))
* **alerts:** add persisted evidence evaluator ([07310e0](https://github.com/icoretech/codex-pooler/commit/07310e0bdba370a88e2923216ecb915dbfdec427))
* **alerts:** add webhook delivery adapter ([0e3147a](https://github.com/icoretech/codex-pooler/commit/0e3147a7cd7eb08ddaeca6c767d70328956d4089))
* **alerts:** add webhook payload signing ([3c4d162](https://github.com/icoretech/codex-pooler/commit/3c4d1628349c67248eeae8da48cc57301c83e39c))
* **assets:** add ApexCharts LiveView hooks ([93e2b84](https://github.com/icoretech/codex-pooler/commit/93e2b842e1353e562a79dc250a5b8ad0c87acb89))
* **audit:** scope audit log visibility ([febf08e](https://github.com/icoretech/codex-pooler/commit/febf08e8c669faee7c22e4b6f975a3ffd3e41047))
* **events:** relay pool events through postgres ([4ab2e0a](https://github.com/icoretech/codex-pooler/commit/4ab2e0a8b9cac06da9fbefbd09190a8f92cc9daa))
* export ecto query metrics ([4b1a75c](https://github.com/icoretech/codex-pooler/commit/4b1a75c80bd6feb9a524113094cc21407f2f49b2))
* **gateway:** carry forwarded metadata in request options ([ff00b77](https://github.com/icoretech/codex-pooler/commit/ff00b77cf202f3a343699ad9fa11e95568827c3a))
* **gateway:** expose codex model tool mode ([22c85f7](https://github.com/icoretech/codex-pooler/commit/22c85f797f00ad7c3b85e2de71355e02dadb1800))
* **gateway:** synthesize upstream codex user-agent ([257951f](https://github.com/icoretech/codex-pooler/commit/257951f1afee30d5868754e27452b21ff2f1a368))
* **jobs:** restrict admin job history ([dcb0b17](https://github.com/icoretech/codex-pooler/commit/dcb0b17bccd3f1f317c892eb579111db2d49ffe7))
* **mcp:** attach operator scope to tokens ([b9ad512](https://github.com/icoretech/codex-pooler/commit/b9ad512601e1dd7eeb15c030501f0a919e40a381))
* **mcp:** restrict operator metadata tools ([9e02816](https://github.com/icoretech/codex-pooler/commit/9e0281667e3bae8df58ee8d44f67be1d11361270))
* **mcp:** scope log metadata tools ([f27aa02](https://github.com/icoretech/codex-pooler/commit/f27aa02ab52dafa7490f432f768d38d998627b58))
* **mcp:** scope pool metadata tools ([5356810](https://github.com/icoretech/codex-pooler/commit/5356810a747eeb6cba77f206f93042bc41636788))
* **mcp:** scope quota metadata tools ([62bc8bc](https://github.com/icoretech/codex-pooler/commit/62bc8bcc21737f5bf504b8eef64d27cb2ff88cbe))
* **openai:** track translated request origins ([bad25fb](https://github.com/icoretech/codex-pooler/commit/bad25fbb679cf1bca76b7e75475cf96980684d95))
* **payloads:** parse transient prompt cache keys ([bbeee42](https://github.com/icoretech/codex-pooler/commit/bbeee42285f83b5e1b74a5c2d603fe69e1ea1602))
* **pools:** add operator pool assignments ([f3a5cb4](https://github.com/icoretech/codex-pooler/commit/f3a5cb427b383ff9024c95214d21f2568943a6f5))
* **pools:** add prompt cache affinity setting ([519b9d8](https://github.com/icoretech/codex-pooler/commit/519b9d8f3b59a388485b7c3d72fd1a17ab13f6b9))
* **pools:** enforce assigned pool visibility ([5bba627](https://github.com/icoretech/codex-pooler/commit/5bba627bee7a7e81fa270d93d2df7126692d00da))
* **quota:** add credit-backed secondary probe routing ([c3bc587](https://github.com/icoretech/codex-pooler/commit/c3bc587e977c3b65a3fbec056b54dc01c56cd7c4))
* **routing:** add prompt cache locality ordering ([c8240ec](https://github.com/icoretech/codex-pooler/commit/c8240ece993484833c9e47d0936f7bd6b617dbfb))
* **runtime:** accept opencode continuity headers ([a862128](https://github.com/icoretech/codex-pooler/commit/a862128b96d67adc3877114c9f3e61ecc7e72e60))
* **runtime:** add codex alpha search proxy ([af11721](https://github.com/icoretech/codex-pooler/commit/af11721bc7f431ea03dfa62729a4f0f70dfa0040))
* **settings:** add per-operator datetime display preferences ([f5f3733](https://github.com/icoretech/codex-pooler/commit/f5f373358e1241cdf5430195c33caab5d2ee2a81))
* **settings:** classify upstream codex user-agent ([834e59c](https://github.com/icoretech/codex-pooler/commit/834e59cd8ab23ea29ce92d0edd6519e881c4914b))
* **settings:** store upstream codex user-agent ([8ecb78b](https://github.com/icoretech/codex-pooler/commit/8ecb78b86be60bb09d7b5c5c99cee8fb28b712b4))
* **smoke:** add openclaw real smoke helper ([5fd2923](https://github.com/icoretech/codex-pooler/commit/5fd2923d185a378566284fa8529cd54cbf978da4))
* streamline admin pool and dialog surfaces ([8799238](https://github.com/icoretech/codex-pooler/commit/879923893414b1eba1913300a8d013249dab31c3))
* **telemetry:** add role memory diagnostics ([9236153](https://github.com/icoretech/codex-pooler/commit/9236153db754422aa3054090dbc6f6a596cab05f))
* **telemetry:** expand memory triage metrics ([b0d0380](https://github.com/icoretech/codex-pooler/commit/b0d03809a882ca7f0252fb545b0e4cea9ca434f4))
* **telemetry:** include stacktraces in memory sampler ([3548d78](https://github.com/icoretech/codex-pooler/commit/3548d78b0f5ffc32ef627b27449b58b63db7204f))
* **upstreams:** add workspace slot identity safeguards ([ed8f9c2](https://github.com/icoretech/codex-pooler/commit/ed8f9c230cb1f91abe0ff48fead75f84d684d61a))
* **upstreams:** enforce assigned pool visibility ([9c79328](https://github.com/icoretech/codex-pooler/commit/9c793285a835e70b4b8eb1897055d994cb81eae0))
* **upstreams:** persist account emails ([58cf2d8](https://github.com/icoretech/codex-pooler/commit/58cf2d82ecbff7cc275f40d325685fbf470ab7f7))
* **upstreams:** support account label renames ([baab2fd](https://github.com/icoretech/codex-pooler/commit/baab2fdb696b7494d6a1b5f204b7c38dc30b8e84))
* **v1:** add responses websocket route ([ab27766](https://github.com/icoretech/codex-pooler/commit/ab277668f9d475063ce92cef54a1df67fdc588e9))
* **websocket:** add bounded lifecycle logger ([467db58](https://github.com/icoretech/codex-pooler/commit/467db585c2cdba67f62402b9f77e8a0fbd87d688))


### Bug Fixes

* **access:** allow scale api key tier ([73d3622](https://github.com/icoretech/codex-pooler/commit/73d3622693628910688144758a5e17eb0c9dd42b))
* **access:** remove ultrafast api key tier ([89974b7](https://github.com/icoretech/codex-pooler/commit/89974b7d9c2719f8856a31ca14e0c51657e4bc83))
* **access:** store invited account email ([81503d0](https://github.com/icoretech/codex-pooler/commit/81503d068ea70c2ae4a6b51dfb902b250bfda822))
* **accounting:** aggregate reservation windows in database ([0c8f765](https://github.com/icoretech/codex-pooler/commit/0c8f7651c1e3d6dc3a5f6dff1dc236e46b112853))
* **accounting:** price owner-forwarded websocket usage ([64eddf5](https://github.com/icoretech/codex-pooler/commit/64eddf5818b365c5466d9de224793665b8122357))
* **accounting:** project request log debug metadata ([b0ad798](https://github.com/icoretech/codex-pooler/commit/b0ad798b3ac03e4da19c31bf790631e235edee3b))
* **accounting:** snapshot upstream account emails ([4611407](https://github.com/icoretech/codex-pooler/commit/46114073af7d7d388353ea862df499faa1b7c95a))
* **accounting:** summarize pinned reauth denials safely ([4fc1be7](https://github.com/icoretech/codex-pooler/commit/4fc1be7b0b6491c12ff0c02cb61e84929a52bca9))
* add admin jobs performance indexes ([457f40d](https://github.com/icoretech/codex-pooler/commit/457f40de6ff8bc15db26ef0f0415b3db241da6fb))
* add token state to upstream card footer ([34621b5](https://github.com/icoretech/codex-pooler/commit/34621b5bbe7c7971246fcc02118ccf9ba607ce4e))
* **admin:** add request log metadata icons ([5532d74](https://github.com/icoretech/codex-pooler/commit/5532d745c545b65f08ab197ebe6f1319935445e4))
* **admin:** avoid misleading quota chart zeros ([cb37798](https://github.com/icoretech/codex-pooler/commit/cb377989d37ed9edcd3bff1da96196191f3e3698))
* **admin:** clarify pool quota availability ([287ef8c](https://github.com/icoretech/codex-pooler/commit/287ef8caf3b7bda20279a809d60c3f80448c7bd7))
* **admin:** clarify request logs header copy ([04cbcd4](https://github.com/icoretech/codex-pooler/commit/04cbcd4d9cff30c619d2bbfa7c3d24584083b8cb))
* **admin:** clarify upstream quota refresh status ([ad8a436](https://github.com/icoretech/codex-pooler/commit/ad8a4365e328e5dc3d8841415d381ad68f8be003))
* **admin:** contain admin shell scrolling ([06e78fa](https://github.com/icoretech/codex-pooler/commit/06e78fa7758a63e9d5989f70c7d5fcb8696cb412))
* **admin:** prefill reinvites from account email ([2706062](https://github.com/icoretech/codex-pooler/commit/270606276a1b00c43feef10be5c220244ecf728c))
* **admin:** preserve live chart updates ([90320a9](https://github.com/icoretech/codex-pooler/commit/90320a934c32373f62a4d51fd56930515a31ad71))
* **admin:** refine system jobs presentation ([4694235](https://github.com/icoretech/codex-pooler/commit/46942351a8330755adc5737f5baf6f7696cec356))
* **admin:** remove ultrafast api key option ([a12f17d](https://github.com/icoretech/codex-pooler/commit/a12f17d09d068009f4df64c8660131cbecdb8933))
* **admin:** show renamed upstream accounts in request logs ([0f8266d](https://github.com/icoretech/codex-pooler/commit/0f8266d8cc832f3e3d0ebe1a16822a2a12062772))
* **admin:** simplify access admin page titles ([548357e](https://github.com/icoretech/codex-pooler/commit/548357ea6a8dad37a576c21e6237c7641befa376))
* **admin:** simplify fast mode display ([41d6db3](https://github.com/icoretech/codex-pooler/commit/41d6db33e69071026c5acb1c3f34743e41f04c69))
* **admin:** simplify operations admin page titles ([6ec63eb](https://github.com/icoretech/codex-pooler/commit/6ec63ebb69f1b27377355b66c62546bac3c2f425))
* **admin:** simplify traffic admin page titles ([a05db01](https://github.com/icoretech/codex-pooler/commit/a05db01f958cad6cc36b9a637ef4172aec8708cf))
* **admin:** suffix core admin page titles ([18ed78c](https://github.com/icoretech/codex-pooler/commit/18ed78ca2224301ecd0b6bc9b9990430af6a83ee))
* **alerts:** enqueue incident deliveries ([9261429](https://github.com/icoretech/codex-pooler/commit/9261429a6972cc68c5a643ecac6c3f5b1b1a0e77))
* align pool metrics footer ([ff953ba](https://github.com/icoretech/codex-pooler/commit/ff953ba7b4e9469a18b72d3d40a1261ef1d772b6))
* align upstream card header content ([1dfa076](https://github.com/icoretech/codex-pooler/commit/1dfa0764d70f8cd643b5df72f6a4c3be97ce6fd3))
* allow internal metrics scrapes without ssl redirect ([7817814](https://github.com/icoretech/codex-pooler/commit/78178143f3a9a5dcf949060ebd535dc14e506707))
* **auth:** require reauth for reused refresh tokens ([ff7d652](https://github.com/icoretech/codex-pooler/commit/ff7d6528d450dd5aea7dd96e6e1e1c3aec304a92))
* bound incomplete stream buffers ([aaf6779](https://github.com/icoretech/codex-pooler/commit/aaf67790c2077377a6b5756eb5b1be79a78cc007))
* **browser-security:** allow local Codex annotation CSP ([848909d](https://github.com/icoretech/codex-pooler/commit/848909df871cb1fda228507a715ab52df28c5796))
* **browser-security:** centralize csp ownership ([f95f2bd](https://github.com/icoretech/codex-pooler/commit/f95f2bd512b3a7623ef7385e6761fd48f244643a))
* **chart:** harden app drain rollout ([8ab92d7](https://github.com/icoretech/codex-pooler/commit/8ab92d7561cf4bf26a4ab5e29fea46078ee2aafa))
* **chart:** harden oban rollouts ([43e45a4](https://github.com/icoretech/codex-pooler/commit/43e45a49fe34898d671b0e128b135f35a9855833))
* **chart:** label app service for metrics ([54110b3](https://github.com/icoretech/codex-pooler/commit/54110b34e2782d43694d9ab53cb6d419dbedf4ec))
* clarify pool card footer metrics ([14d096a](https://github.com/icoretech/codex-pooler/commit/14d096ad5c0914b70ce33a7feb1bf3a253ba026c))
* clean up admin card selectors ([93cff76](https://github.com/icoretech/codex-pooler/commit/93cff76644cf6004e4fd3c84fcac56d2b5938eb5))
* **deps:** update apexcharts to 5.14.0 ([9fade27](https://github.com/icoretech/codex-pooler/commit/9fade2780825ec3f0b9e87250696d18764cabbfb))
* **deps:** update astro monorepo to v6.4.3 ([#16](https://github.com/icoretech/codex-pooler/issues/16)) ([a125fac](https://github.com/icoretech/codex-pooler/commit/a125fac4115ba09a48374f91562bb60eb375a262))
* **deps:** update dependency @astrojs/starlight to v0.39.3 ([#15](https://github.com/icoretech/codex-pooler/issues/15)) ([1870d4c](https://github.com/icoretech/codex-pooler/commit/1870d4c9ef7fb18158013f6f385463238176fb0a))
* **deps:** update docs yaml tooling ([4ff4e41](https://github.com/icoretech/codex-pooler/commit/4ff4e41ad89f04c3d0511a41cca3497706012aed))
* **dev:** load upstream secret env for host mix ([01654d7](https://github.com/icoretech/codex-pooler/commit/01654d75793246affe4856c29e135120a515fc56))
* **docker:** use italian debian mirrors ([b18e0fb](https://github.com/icoretech/codex-pooler/commit/b18e0fb071d96f622eb5a7ff958de28b8b6a2081))
* **events:** suppress local pubsub echoes ([048564c](https://github.com/icoretech/codex-pooler/commit/048564c9ee96286fcf8adb74f1661b36efc0465a))
* **events:** tighten postgres relay flow ([8c8c2d1](https://github.com/icoretech/codex-pooler/commit/8c8c2d1ea02f4b9d6a56926d446744945ac23568))
* expand single upstream quota limits ([3efcd2e](https://github.com/icoretech/codex-pooler/commit/3efcd2e277ddfe5cd1464d96e97347f3e624a115))
* **gateway:** add pinned reauth recovery contract ([7fd60e2](https://github.com/icoretech/codex-pooler/commit/7fd60e27338fb253c9180f8d079db0f8a4165bf7))
* **gateway:** bound retained stream bodies ([20608e3](https://github.com/icoretech/codex-pooler/commit/20608e3ac7a4f5a311a4c79c6e3642f4d5515fef))
* **gateway:** bound retained websocket bodies ([5c90ab4](https://github.com/icoretech/codex-pooler/commit/5c90ab4a329a8b889aa81e475e7acf710f7420a3))
* **gateway:** classify pinned reauth continuations ([c9fa984](https://github.com/icoretech/codex-pooler/commit/c9fa9841cdb68d8735f321adec33885290496cf5))
* **gateway:** classify usage-limit terminal events ([bb1c45e](https://github.com/icoretech/codex-pooler/commit/bb1c45e9a5733b838388612e08516896a1a08218))
* **gateway:** forward codex responses metadata headers ([862a069](https://github.com/icoretech/codex-pooler/commit/862a069772466727fa76bd158da9fb99bc7aba97))
* **gateway:** handle wrapped mint protocol errors ([dcbe9a9](https://github.com/icoretech/codex-pooler/commit/dcbe9a9dbc3608fe903ec206b349cbba1496a776))
* **gateway:** ignore non-quota websocket frames ([6340efa](https://github.com/icoretech/codex-pooler/commit/6340efab0e52c33ebe4e9c1b726fae4418fe8089))
* **gateway:** mark visible stream output once ([f9c95b1](https://github.com/icoretech/codex-pooler/commit/f9c95b1ce7086d678024db69e1f2f53f3bfcebf3))
* **gateway:** parse websocket response usage ([1eb7899](https://github.com/icoretech/codex-pooler/commit/1eb789964b1269b9cfb39d29f64d940420d93959))
* **gateway:** recover session start conflicts ([debaa1b](https://github.com/icoretech/codex-pooler/commit/debaa1b5bcbba2364e17cd7cc4c62b06a312d9db))
* **gateway:** release websocket payloads during upstream waits ([a7b71c8](https://github.com/icoretech/codex-pooler/commit/a7b71c87da8feeb7aa911b5ee77b321f194022a6))
* **gateway:** settle websocket usage costs ([331e5a7](https://github.com/icoretech/codex-pooler/commit/331e5a7bd60deaeb496038910f46324bb4156481))
* **gateway:** soften local continuity quota pinning ([eb174ee](https://github.com/icoretech/codex-pooler/commit/eb174ee00870fba7010b8aa84b57622b86c4a764))
* **gateway:** synthesize responses lite markers ([635f2af](https://github.com/icoretech/codex-pooler/commit/635f2affd49b581b4699c97e7e88fbe09fd13b78))
* **health:** drain readiness with marker ([711a6f4](https://github.com/icoretech/codex-pooler/commit/711a6f4a01274800329b0f32803a9dea8748c9ad))
* **helm:** raise memory ([ad4c84c](https://github.com/icoretech/codex-pooler/commit/ad4c84cefe9a5ddff547155bf6cd51cb6b7d9666))
* **helm:** raise to 1millicore ([e5d0cce](https://github.com/icoretech/codex-pooler/commit/e5d0cced03a5af14201ca5d020f3c80379157e66))
* **ingress:** accept larger compressed codex replays ([318942c](https://github.com/icoretech/codex-pooler/commit/318942c647fb13faf8e5d2bc8bd5f1dfc2530bc8))
* **jobs:** configure oban shutdown grace ([e299e41](https://github.com/icoretech/codex-pooler/commit/e299e4175bc6769761464a9563d2e2617b07de6e))
* keep fresh stream sessions routable ([7d236d3](https://github.com/icoretech/codex-pooler/commit/7d236d3fee95b5d2ef91b4452a8acf9ad36184fb))
* keep sse server errors circuit-neutral ([05b04e8](https://github.com/icoretech/codex-pooler/commit/05b04e87469ac343ddaca6f2756ed2e20c24c784))
* keep upstream actions menu in card header ([ce0edb0](https://github.com/icoretech/codex-pooler/commit/ce0edb04926a6fae37310baae15a3ae745d9847b))
* make admin sidebar navigation scrollable ([c198cf2](https://github.com/icoretech/codex-pooler/commit/c198cf24bb2bd8f4c37bdc275ec539ff2c7df084))
* match pool wizard plan badge style ([282578d](https://github.com/icoretech/codex-pooler/commit/282578d30e72e6bc3698b5571607148a602fcb57))
* **mcp:** expose request log debug fields ([e0114d8](https://github.com/icoretech/codex-pooler/commit/e0114d85badee3ff42d2759cb94e54713e565253))
* **mcp:** expose stored upstream account email ([09fdc3b](https://github.com/icoretech/codex-pooler/commit/09fdc3b2274c4173e6e28711701882d7b0596785))
* **mcp:** ignore blank quota filters ([9fbb61c](https://github.com/icoretech/codex-pooler/commit/9fbb61ccc50cbe07ed81a0329ad887eaf7ac97ce))
* **mcp:** keep error results schema-safe ([fd2fc4f](https://github.com/icoretech/codex-pooler/commit/fd2fc4f89a69c515919b1aba4d5430131241986e))
* **mcp:** match request log metadata ids ([49803f5](https://github.com/icoretech/codex-pooler/commit/49803f5d56e88c1f3a3e1dc407b3b42f1bc75b82))
* **mcp:** sanitize pinned reauth log metadata ([d191533](https://github.com/icoretech/codex-pooler/commit/d19153375c957c5e78664bb6942919fe447e4935))
* move upstream readiness to card footer ([5245eb9](https://github.com/icoretech/codex-pooler/commit/5245eb97704c591071df11e51ca4dc3b22497efb))
* **openai:** accept current moderation and reasoning shapes ([42f5628](https://github.com/icoretech/codex-pooler/commit/42f5628fbbcf304117786b033c81f6a7ad83c11b))
* **openai:** emit chat usage stream chunks ([d25f4cb](https://github.com/icoretech/codex-pooler/commit/d25f4cb99d9bd0c953f5c4ccb0c2052a07498ff3))
* **openai:** normalize supported SDK controls ([ef9b983](https://github.com/icoretech/codex-pooler/commit/ef9b9837f9ec2f24b7e115c382c395051da088ae))
* **openai:** reject unsafe reasoning effort values ([30f9870](https://github.com/icoretech/codex-pooler/commit/30f987096e005e8dfc9053808c74b4df7788483b))
* **payloads:** bound prompt cache keys ([4a3f600](https://github.com/icoretech/codex-pooler/commit/4a3f600c6f3fef04d5646a97665edfc003953592))
* **pools:** polish admin pool cards ([20bd39c](https://github.com/icoretech/codex-pooler/commit/20bd39cf42d99395687f83e9272caca8bd56845d))
* preserve oversized public responses SSE events ([5e7a2bd](https://github.com/icoretech/codex-pooler/commit/5e7a2bd3fc9f44e265cc978aef7eff4a98b07838))
* prevent upstream card row stretching ([5532ff1](https://github.com/icoretech/codex-pooler/commit/5532ff1cc7ee91372464bea8dc70a4579ae581a6))
* **pricing:** default openai catalog to github pages ([601bd8a](https://github.com/icoretech/codex-pooler/commit/601bd8affa21cf29494f3e72af1ca7ff1aa30ec7))
* **quota:** preserve explicit zero credits ([a6c6e0a](https://github.com/icoretech/codex-pooler/commit/a6c6e0aba79feec837f2d6af8cb2772da4da14eb))
* **quota:** preserve newer usage resets ([929caed](https://github.com/icoretech/codex-pooler/commit/929caed87f2e7889a2862abf76c74f140b678b04))
* **quota:** project credit-backed probe state ([c4a81e6](https://github.com/icoretech/codex-pooler/commit/c4a81e61db5687304e0069ec68986b65adf0f309))
* **reconciliation:** expose failed quota refreshes ([f890037](https://github.com/icoretech/codex-pooler/commit/f8900375517a76e9a2d648f54202849932963060))
* reduce upstream card title size ([2555a88](https://github.com/icoretech/codex-pooler/commit/2555a888a0561e82326548d7c25d0e11d4eeea05))
* refine admin card headers ([a720899](https://github.com/icoretech/codex-pooler/commit/a72089909312bc86e1a4cc32f294193aacaa0a4a))
* refine system jobs interactions ([38dca7a](https://github.com/icoretech/codex-pooler/commit/38dca7a8d5297293d40ab354c83ba635affd9f24))
* **release:** return pricing import result ([d5a3101](https://github.com/icoretech/codex-pooler/commit/d5a31019672826750b87d156a99042aefd34610f))
* **release:** start repo for pricing import ([f662b64](https://github.com/icoretech/codex-pooler/commit/f662b64f492c511420c35a9241f5b211f4f5261d))
* remove onboarding privacy notice card ([71caae9](https://github.com/icoretech/codex-pooler/commit/71caae913e24ee6b60d09798633630fdb915ea05))
* remove pool metric helper captions ([56a1581](https://github.com/icoretech/codex-pooler/commit/56a158160eeab250f03fd3cae749263d259f24bf))
* remove upstream add capacity card ([9cb835e](https://github.com/icoretech/codex-pooler/commit/9cb835e04556a3c6ed083d6804b2d268950e12f9))
* rename pool TPS metric label ([341c031](https://github.com/icoretech/codex-pooler/commit/341c031370ee8155ac866fc5b0fc393ad3d94144))
* **renovate:** include mise elixir runtime updates ([a3d2be1](https://github.com/icoretech/codex-pooler/commit/a3d2be1d1ac1d71b82591b272cff53a9a6ccb093))
* **requests:** cover archived pool log filters ([9ef8985](https://github.com/icoretech/codex-pooler/commit/9ef8985a971f86dd1b317006a62bc1ca0ab738fd))
* reuse plan badges in pool wizard ([016299d](https://github.com/icoretech/codex-pooler/commit/016299da3776eb3dc35337e9280cfafd52f110b3))
* **runtime:** support elixir 1.20.0 ([e5689b5](https://github.com/icoretech/codex-pooler/commit/e5689b5205a78eb3336bf991b47b205b811ec92a))
* **runtime:** use synthetic user-agent for upstream callers ([c93e02a](https://github.com/icoretech/codex-pooler/commit/c93e02a9e5426871fdbd6b56223ea5ae4b24cee4))
* **security:** expose browser CSP to quality scan ([4051590](https://github.com/icoretech/codex-pooler/commit/405159054fc41bee1c4aacf6bb08833aea4ebcd2))
* **settings:** backfill development flags ([988d02c](https://github.com/icoretech/codex-pooler/commit/988d02c57ca1aabba7691f909289e321873aee41))
* **settings:** refresh cached gateway defaults ([139a375](https://github.com/icoretech/codex-pooler/commit/139a37540eb45595f2b4d81dbdbce23f46302a6c))
* simplify admin jobs explorer ([3811df6](https://github.com/icoretech/codex-pooler/commit/3811df6afb6356d78eb7347c7fb79ff0bf903f52))
* simplify pool row telemetry ([c0bef0a](https://github.com/icoretech/codex-pooler/commit/c0bef0aa55df42ea8d6b1160682bf231c5842521))
* skip live reload for Codex desktop browser ([3f3f509](https://github.com/icoretech/codex-pooler/commit/3f3f5096d19ce10a56d3544f1c23e1cc31482151))
* soften pool traffic chart styling ([15c3667](https://github.com/icoretech/codex-pooler/commit/15c3667d8d855aff71b39954c6f79c680b617496))
* speed up admin jobs failure interactions ([31c3acc](https://github.com/icoretech/codex-pooler/commit/31c3acc29a652c626b1da8f45a1fa2d52f3a33ee))
* split upstream footer metadata cells ([ca38a28](https://github.com/icoretech/codex-pooler/commit/ca38a2871aeeb89fb6514d4ee47dd98f792151c1))
* stabilize invites table layout ([6e50acf](https://github.com/icoretech/codex-pooler/commit/6e50acf62849b354759a4c56d8cd8264e145023f))
* **streaming:** buffer incomplete response sse chunks ([2c39016](https://github.com/icoretech/codex-pooler/commit/2c390165d390dabfe3e40dc3b01a6881ad47e2dc))
* **streaming:** canonicalize typeless websocket failures ([396e9e7](https://github.com/icoretech/codex-pooler/commit/396e9e7844638a647bd5cebcedb2abd027ed5ff6))
* **streaming:** clean up covered sse chunk clause ([6d65344](https://github.com/icoretech/codex-pooler/commit/6d65344b518f9af1f9f7eebfef794a8e846c19ab))
* **streaming:** surface websocket idle timeouts ([dad0185](https://github.com/icoretech/codex-pooler/commit/dad01854d75562b2688ae518a36d60da91cd301c))
* **telemetry:** skip prometheus reporter on oban roles ([c8a0bb2](https://github.com/icoretech/codex-pooler/commit/c8a0bb201686b8ad7bd87ac077698ade7245bcc2))
* **test:** serialize shared database test runs ([0672928](https://github.com/icoretech/codex-pooler/commit/0672928620cfba7bea817cf9f12122a7ab796f45))
* **tests:** isolate last active admin check ([f6e0b50](https://github.com/icoretech/codex-pooler/commit/f6e0b501b3983a25f244657379cf885b235bdcc6))
* **tests:** stop websocket owner sessions ([03d6d2b](https://github.com/icoretech/codex-pooler/commit/03d6d2b5f8b2fe8dae2caec3e49580302a5e84c7))
* tighten admin chart tooltips ([566135c](https://github.com/icoretech/codex-pooler/commit/566135cc63bbed2aed1466f9d73700a1235b0ed1))
* tighten admin jobs page ([b2f17b4](https://github.com/icoretech/codex-pooler/commit/b2f17b4bacc9e8001ba66feb36c3008460caf726))
* tighten admin notice body leading ([a9b3499](https://github.com/icoretech/codex-pooler/commit/a9b3499cc050c9935965e090e370add694bd9185))
* **ui:** align public auth branding ([ddfddd9](https://github.com/icoretech/codex-pooler/commit/ddfddd9c8a1c91b06ef6c9bcb72d95293abd4d57))
* **upstreams:** preserve custom labels on recovery reuse ([80ededf](https://github.com/icoretech/codex-pooler/commit/80ededf8d6ba35bf3ff816cc918c9df4e2c9c77d))
* **upstreams:** preserve unknown quota chart remaining ([4eef314](https://github.com/icoretech/codex-pooler/commit/4eef3141b49248fec61bdfebdee978d8ad9f2ec3))
* **upstreams:** reject pat auth json imports ([38b4d62](https://github.com/icoretech/codex-pooler/commit/38b4d62493c94f333cbd844d557490c18680bf93))
* **upstreams:** store auth json account email ([d790fb9](https://github.com/icoretech/codex-pooler/commit/d790fb97de389966c1e56334a18d39372f59933b))
* **v1:** accept image generation output format ([41d497f](https://github.com/icoretech/codex-pooler/commit/41d497f5bc81c14a7dd77a5df618fc03287cc073))
* **v1:** accept opencode ordinary replay ([c05a878](https://github.com/icoretech/codex-pooler/commit/c05a878c36251fc95d3595b2659416182a804a12))
* **v1:** accept opencode replay response items ([d7b833c](https://github.com/icoretech/codex-pooler/commit/d7b833cfc80301691f724232ba453e85fc20cfe1))
* **v1:** accept truncation without upstream forwarding ([ea8da10](https://github.com/icoretech/codex-pooler/commit/ea8da1006b5364885bda744681b4d7ca5a816eb0))
* **v1:** coerce public websocket creates ([83cf027](https://github.com/icoretech/codex-pooler/commit/83cf02747d8628258fb706a8f5cb258e42867a10))
* **v1:** coerce public websocket response frames ([0434a50](https://github.com/icoretech/codex-pooler/commit/0434a50421536f335247da6615dc6446f03af0be))
* **v1:** recover opencode native replay call ids ([0d03e9e](https://github.com/icoretech/codex-pooler/commit/0d03e9ea71be9be3e11b5cc852373338c4e8f361))
* **v1:** reject ultrafast service tier ([862c61e](https://github.com/icoretech/codex-pooler/commit/862c61edbf578b1f0e778e6cf3eaa3efbe6de257))
* **v1:** route media models through host capacity ([ef40a69](https://github.com/icoretech/codex-pooler/commit/ef40a69fc88897c961e3656dfb58a3320447ccda))
* **v1:** send generate flag on public websocket frames ([3edb238](https://github.com/icoretech/codex-pooler/commit/3edb238c116d18c552b327f5f3cabacc2c0df7ff))
* **v1:** support chat input fallback and additional_tools ([f769d84](https://github.com/icoretech/codex-pooler/commit/f769d849196be51cf2919f1e575de328281f6336))
* **websocket:** cancel owner worker on detach ([437c374](https://github.com/icoretech/codex-pooler/commit/437c3748fbbeb24094abd498b62cc2c2723a7064))
* **websocket:** capture frame error headers ([de96f46](https://github.com/icoretech/codex-pooler/commit/de96f4637bc3e579c2970b7da3b471978da60342))
* **websocket:** classify graceful owner monitor exits ([9df8858](https://github.com/icoretech/codex-pooler/commit/9df88580d4fee5a204b9fb727967b4b369bf64f4))
* **websocket:** classify wrapped stream errors ([b2def15](https://github.com/icoretech/codex-pooler/commit/b2def1570bcaaa4eb94d8f5f34ee9f151081cee6))
* **websocket:** close owner crash sockets cleanly ([4d808a9](https://github.com/icoretech/codex-pooler/commit/4d808a9e914f27404155ea681f6fae8a9d5f66ed))
* **websocket:** drain local response tasks after cleanup ([bcfa988](https://github.com/icoretech/codex-pooler/commit/bcfa98850a9a79501aeda6209dd0820798ee9597))
* **websocket:** drain owner response tasks briefly ([eedb87a](https://github.com/icoretech/codex-pooler/commit/eedb87ae4105bbdae6ea25d276d42808456d50b9))
* **websocket:** drain response tasks on close ([3297c9e](https://github.com/icoretech/codex-pooler/commit/3297c9ee97254c49aa05c4ed2c700f0a822f0438))
* **websocket:** finalize client disconnect turns ([bd9c512](https://github.com/icoretech/codex-pooler/commit/bd9c51221b9dce28981e3eef2d97661425e85d43))
* **websocket:** finalize owner turns on downstream close ([8468b6d](https://github.com/icoretech/codex-pooler/commit/8468b6da555a918b93f0568b596bc7e43036248c))
* **websocket:** ignore stale owner monitor exits ([bb2c670](https://github.com/icoretech/codex-pooler/commit/bb2c670d4ebb1d4af4b276f3315ff3958913a0f3))
* **websocket:** persist quota evidence from frames ([8bfe211](https://github.com/icoretech/codex-pooler/commit/8bfe211f2ae8134bad98c3739fd02e5d425cdb32))
* **websocket:** preserve interrupted owner turns ([0f6e63b](https://github.com/icoretech/codex-pooler/commit/0f6e63ba63d99d0c9c9b8f6dadaa23951a0ccfa1))
* **websocket:** preserve owner auth failures ([0b2e4cd](https://github.com/icoretech/codex-pooler/commit/0b2e4cdc71f98f2c8b8e33524a672190952b3695))
* **websocket:** preserve remote owner result types ([032e0ee](https://github.com/icoretech/codex-pooler/commit/032e0eeedd8533323f2d79b1ac7ea47d07b2618a))
* **websocket:** recover crashed owner sockets ([ced5fd8](https://github.com/icoretech/codex-pooler/commit/ced5fd8ce63c1d1637959647dd6d1a3d9b61ec9e))
* **websocket:** recover missing local owners during dispatch ([aec014f](https://github.com/icoretech/codex-pooler/commit/aec014f0ce0d21655ebd23eb1c97b8df8a5c6f58))
* **websocket:** recover missing remote owners during dispatch ([6ec272e](https://github.com/icoretech/codex-pooler/commit/6ec272e4c279aabe38fdda2a5938129955cd69af))
* **websocket:** recover owner lifecycle leftovers ([bd9c567](https://github.com/icoretech/codex-pooler/commit/bd9c5675ddd854209ad671c4f5c112bb011fb7c5))
* **websocket:** reduce recovered owner takeover alarm ([3cbe035](https://github.com/icoretech/codex-pooler/commit/3cbe0353ef38cf952dd7e9699ae3320718661d92))
* **websocket:** refresh terminal auth before output ([4d664a4](https://github.com/icoretech/codex-pooler/commit/4d664a49128438ea40165a8ba03e9928ad674b81))
* **websocket:** remove unreachable owner renewal guard ([fc90147](https://github.com/icoretech/codex-pooler/commit/fc9014799bba2ca4059bbdd64fadc6e0a77044b2))
* **websocket:** renew live owner leases ([7e3f2b4](https://github.com/icoretech/codex-pooler/commit/7e3f2b46dc61c23f61a13fdd752c9d001f897457))
* **websocket:** replace stale local owners before dispatch ([f5d7564](https://github.com/icoretech/codex-pooler/commit/f5d75644e751531d4203e43b7914da6b0406e342))
* **websocket:** report early close lifecycle ([e15300e](https://github.com/icoretech/codex-pooler/commit/e15300e024a02a73f11870642cb8e31ee1d159f0))
* **websocket:** retry connection limits before output ([f13ae05](https://github.com/icoretech/codex-pooler/commit/f13ae058be91a09c779eb69ef8adc1c981441e6a))
* **websocket:** return owner request results ([99b1cfc](https://github.com/icoretech/codex-pooler/commit/99b1cfcf7984ee22895b3afdda90fa0e704493bb))
* **websocket:** sanitize terminal event headers ([064abda](https://github.com/icoretech/codex-pooler/commit/064abda09d8e6896c5defcb4a5f75eaf3b0daae3))
* **websocket:** store sanitized frame metadata ([d5775c8](https://github.com/icoretech/codex-pooler/commit/d5775c88ffc7ccbce07cdf6109acbc2c09f1dfbc))
* **websocket:** suppress cleanup-only owner detach warnings ([e9d936b](https://github.com/icoretech/codex-pooler/commit/e9d936bf9c59c50a1290c4d0a2b05e4cc23fd3d5))
* **websocket:** take over drained local owners during dispatch ([4b346e6](https://github.com/icoretech/codex-pooler/commit/4b346e630ce47056dcd4a79ff79fe1bb1ec43e46))
* **websocket:** wait for typed terminal events ([b86cbd2](https://github.com/icoretech/codex-pooler/commit/b86cbd24bd87be01f34c9ad73bdc6145f7248501))


### Performance Improvements

* **access:** debounce api key touches ([e535182](https://github.com/icoretech/codex-pooler/commit/e535182900ec0d11a5de54b9427ed89e97c38102))
* **accounting:** avoid settlement rereads ([be0239c](https://github.com/icoretech/codex-pooler/commit/be0239c43546f679ef57aefa91bb6228526b39a9))
* **accounting:** batch ledger window usage ([a02e36e](https://github.com/icoretech/codex-pooler/commit/a02e36e63d22c29318af0a7fe2cd4de66aa49f6e))
* **accounting:** fold final request snapshot writes ([4d19eb3](https://github.com/icoretech/codex-pooler/commit/4d19eb3b5e834db1282cdcb77cbfc19deb2a4aef))
* **accounting:** lock effective policy once ([95f356e](https://github.com/icoretech/codex-pooler/commit/95f356e526efaa74204e24bbd3d9b4f681c5dcee))
* **accounting:** narrow policy reservation locks ([7b9f189](https://github.com/icoretech/codex-pooler/commit/7b9f1892c72022c4d2ffc3a73ad5ff43459fdd74))
* **accounting:** reuse identity snapshots ([3289d2d](https://github.com/icoretech/codex-pooler/commit/3289d2daab19aac2df1797efcdd79ce3109633e1))
* **admin-jobs:** batch worker-card summaries ([adbb86a](https://github.com/icoretech/codex-pooler/commit/adbb86a8ec4aa12653d4bfa5ad96c07e21f5050f))
* **dev:** expand gateway probe budgets ([473d6c7](https://github.com/icoretech/codex-pooler/commit/473d6c77ac0e08d0e18a92528469f2478613762f))
* **gateway:** add request-local route state ([416c0e4](https://github.com/icoretech/codex-pooler/commit/416c0e4d2c74608ab08e548f9eaa2062134e8501))
* **gateway:** batch quota projection reads ([2c55e43](https://github.com/icoretech/codex-pooler/commit/2c55e43c521ff89490a696ae64d8ae028719d0de))
* **gateway:** carry route snapshots through dispatch ([94de9c9](https://github.com/icoretech/codex-pooler/commit/94de9c9bb365819d8702b727fb3f420067d63bfc))
* **gateway:** defer route metadata writes ([230ae4d](https://github.com/icoretech/codex-pooler/commit/230ae4d984077f2ce528067a565b30e5ae2d1b75))
* **gateway:** reuse control-plane routing settings ([a27a5ed](https://github.com/icoretech/codex-pooler/commit/a27a5ed5f052f84d7252768ff89d8a3ca687a28c))
* **gateway:** reuse hydrated model visibility ([e5b8c71](https://github.com/icoretech/codex-pooler/commit/e5b8c71fc2db0423078b44f3668b0f1787bab060))
* **pools:** expose default routing settings ([7d91f46](https://github.com/icoretech/codex-pooler/commit/7d91f464cd50ebf2bb841fe10231c6e03faa144e))
* **quota:** batch route window snapshots ([0d754d8](https://github.com/icoretech/codex-pooler/commit/0d754d865d772a908e02977ddd6e365132d3bf4e))
* **routing:** batch circuit eligibility snapshots ([5770127](https://github.com/icoretech/codex-pooler/commit/5770127e4ed337e4cd3f0a0e0ca7b1010a942a28))
* **routing:** consume request-local route state ([58b7025](https://github.com/icoretech/codex-pooler/commit/58b7025fc3d2f2e7c32b6c0567aadb2bfe85c4eb))
* **routing:** hydrate model visibility once ([05d83a4](https://github.com/icoretech/codex-pooler/commit/05d83a47a8c2d688fc127ea6d247a6a1762cb33c))
* **routing:** reuse circuit snapshots for selection ([549b511](https://github.com/icoretech/codex-pooler/commit/549b5116b0d548949d6dfc72680b1dddd2aaf5f3))
* **routing:** reuse quota snapshots for ordering ([69754a3](https://github.com/icoretech/codex-pooler/commit/69754a392fdf7b3cd9cf5a9d0bc82b39db2b6fcc))


### Miscellaneous Chores

* release 0.0.1 ([40554ab](https://github.com/icoretech/codex-pooler/commit/40554ab90cd188645fc8bc4195515c68e96eb431))
