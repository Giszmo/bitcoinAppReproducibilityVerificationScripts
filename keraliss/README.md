# Keraliss's build scripts (backup)

Copied 2026-11-18 from Nostr: the newest script attached to a verification for each app below. Each file is the base64 content of a kind 1337 event signed by keraliss (`6274e238b289e1b2e98e4e6ce600dcc0cb2e2c03db9b850260ff8bdd6bbf2a45`), fetched from relay.nostr.info / relay.ditto.pub. Saved byte for byte; not edited, not run.

Why: Carol's `abs-runner` list (Buzz dc thread `49732b5e`) names these as Docker-first scripts ABS still reuses (Keraliss pinned to his 436 events, !1951). None were in this repo's history.

File name = `<appId>_<script name>.sh` (three OneKey scripts share the name `onekey_build`).

| File | appId | Platform | Bytes | sha256 | Script event id | Uploaded (UTC) | Versions verified with it |
|---|---|---|---|---|---|---|---|
| `arcbtc.lnbits.hww_lnbits-hardware-wallet_build.sh` | arcbtc.lnbits.hww | hardware | 15202 | `adea087bfac90202c612b4c06395b8c196b1f160772ec6c50305b2b3df7b739a` | `424565ee9d76e96ab5c7801c4fe7abe7b305343e0159e3d5f651109846c4a801` | 2026-08-29 | 0.8.2 |
| `coldcardMk5_coldcard_build.sh` | coldcardMk5 | hardware | 14085 | `ae137cd4f6511efc1ac9f9c7b61a7edccee70c9024358342f377a9e250a1e19c` | `5a8d20513b05d2fca3ba1399b9d9a978140d2a3ea3e59b53b8742d7b08fe8a1c` | 2026-08-21 | 5.6.1, 5.6.2, 6.6.0X, 6.6.1X |
| `com.lnflash_com.lnflash.flash_build.sh` | com.lnflash | android | 19235 | `0ced93400caaff74c0f5963037d4d29aeba1852eeb2f8dc59f29b3bb00fe7c64` | `af436ef0139fbd746d1917c00c02030bea3484b17805f3a3b42bb15b4ca8ca2a` | 2026-03-01 | 0.4.9 |
| `im.adamant.adamantmessengerpwa_im.adamant.adamant_build.sh` | im.adamant.adamantmessengerpwa | android | 5950 | `afda886bea2b57d95846b7300de68c0c57896dcde3d9ec621461fb410dd12ac8` | `0ed1fcb82cd6775e025018f347a6b1a531971b4ec37054edace6e9a2cbffe66a` | 2026-01-04 | 4.10.6 |
| `kruxdiyhw_krux_m5stickv_build.sh` | kruxdiyhw | hardware | 8888 | `fcaf47d60645efafc7e9dce86018528b3a6661ec9b8674beb916d79c3e261839` | `f27142667bd09f395e9741e9e16b2b8b2e340395a057c64ab19c0d7c70e73fef` | 2026-06-06 | 26.04.0 - m5stickv, 26.08.0 - m5stickv |
| `kruxdiyhw_krux_tzt_build.sh` | kruxdiyhw | hardware | 9278 | `b5d358769bc7e6b756d5397036eebfe5abdeaf4dd9940cad4bb76066b3a5e72b` | `439f2dd8a2356d5ba991ff8f1d2c49b3c7724618fdb2e27060793f9b8426dbad` | 2026-06-06 | 26.04.0 - TZT/EmbedFire/K-Pro, 26.08.0 - TZT/EmbedFire/K-Pro |
| `kruxdiyhw_krux_yahboom_build.sh` | kruxdiyhw | hardware | 9284 | `d8e47acd298b123f4c64fd28909011fe41ce84b2042e60c2be6b420fc5e7c215` | `381b50698c7e77a918305ab2bff28b939c344e34f793137e1f5fad86ba872390` | 2026-08-08 | 26.08.0 - Yahboom/Cube /Wonder |
| `onekey.pro_onekey_pro_build.sh` | onekey.pro | hardware | 14332 | `f7ee21df22a2f89c32f7508c49dfce4ddd8a3dbe53dce78815ea3a2860979ddf` | `caf5eca1981d54fa8b4ead9683b28c674e23db8c60c828df2dedce371224317f` | 2026-07-17 | 4.21.0 - btc-only |
| `onekey.touch_onekey_build.sh` | onekey.touch | hardware | 14195 | `78b4e4050c972086f5ae1139a65523c043824f724ae03edb1599ca14dc54af89` | `306791e51070be5991bd0c3a2f62a482a133ce034176afd1e15b1445cf5636ff` | 2026-05-07 | 4.12.0 |
| `onekey_onekey_build.sh` | onekey | hardware | 13562 | `5bd2d4d733dbc65a7e8a3a002431400e2b6cce8e3c29bbc37dc26a544589584c` | `f682d84e184a6c8a0a4bb3c2a40772b0510e2e0ffd299f1c4bcb7edfe9addec4` | 2026-05-07 | 3.12.0 |
| `onekeymini_onekey_build.sh` | onekeymini | hardware | 17116 | `b0e1a06b30eddb0e485cb54f06b870a11887dd0f81c642f229835c49a1c38acf` | `800443e755f9b70f5ef030b400e59fc47206ba7d07bfbdd6c248ff0fd5de21f9` | 2026-01-24 | 3.10.0 |
| `passportb2_passport_build.sh` | passportb2 | hardware | 12753 | `e3b184fb1046afae9af48976c35f5089730dc9fa0c395bd1c79132e6aef274b2` | `f780443da0d8167372431f81df7edc16299a4419066c5afe77188d1093983e66` | 2026-03-19 | 2.3.11 - Mono |
| `seedsigner_seedsigner_build.sh` | seedsigner | hardware | 8302 | `ef1f7e10b464cc584837b79dc21a24d52dac85a248ab5435134639c1a5b43fbd` | `c8468042f5b171eed3715681bcb5ceb7bec53c2e9d5391f8e390fc9673d921b8` | 2026-07-09 | 0.8.7-pi4 |
| `specter.shield_specter-diy_build.sh` | specter.shield | hardware | 8680 | `3d71e861552cfc4d338fbef7d115d70d215201d07e3e1b58c0ea9a81eadc89a5` | `e366186f268fe2580f9023d9e267c5bf2f5403b74c972f0ad93e5922a52893a3` | 2026-06-06 | 1.10.3 |
| `swiss.dfx.bitcoin_swiss.dfx.bitcoin_build.sh` | swiss.dfx.bitcoin | android | 18214 | `99f1f157aa2e3752120be54fbc42205ae2c3573ad21809529af8d606cc2897a6` | `919a330f52dc84d76bb9d5a3afef2051dce0f38a4a7bf4c7106ad1bb44064ba7` | 2026-02-20 | 2.0.3 |
| `twentytwo.portal_verify_portal.sh` | twentytwo.portal | hardware | 8790 | `e5dbcd9be40ffe2c5dcfc24f74a9fee41a97cfc20f164e2eab648577bf034428` | `6a90a205cb84980a48ce2a27483abc8d47342197b2b449bc3576ab03ca9c150f` | 2026-01-17 | 0.3.4 |

Added 2026-11-18 (second pass, from Carol's clean list `93c00fc1`): coldcard_build, im.adamant.adamant_build, krux_tzt_build, krux_m5stickv_build. Not copied: krux_amigo_build, krux_dock_build (not on Carol's list). `twentytwo.portal_verify_portal.sh` kept, although ABS never runs it (name does not end in build.sh).
