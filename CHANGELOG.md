# Changelog

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
