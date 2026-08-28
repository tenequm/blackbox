# Changelog

## [0.9.4](https://github.com/tenequm/blackbox/compare/v0.9.3...v0.9.4) - 2026-08-28

### <!-- 1 -->New Features
- **transcription:** auto-transcribe finished recordings ([c600b60](https://github.com/tenequm/blackbox/commit/c600b606548bf3251347e1c88d5e55ca11f71a80))
- **ui:** UI and UX fixes ([d280e5f](https://github.com/tenequm/blackbox/commit/d280e5f5810b9c8c224daeb06388f04a8b06812a))
  Transcripts can be selected, copied and followed while playing, and replaced when they come out wrong. The library is searchable, with multi-select export and delete. Transcription runs a job per recording instead of one at a time. Echo cancellation no longer crashes the app.

### <!-- 5 -->Documentation
- correct AEC trigger and note the cooperative-pool constraint ([8b0c432](https://github.com/tenequm/blackbox/commit/8b0c4324bed3974a2759f16953b6fc5634557947))

### <!-- 6 -->Chores
- update swift-macos skill ([00d7f8a](https://github.com/tenequm/blackbox/commit/00d7f8a63ff310ece2191a80c6230518a0154d28))
- macOS 27 readiness - Sparkle 2.9.6 + forward-compatible @State ([#22](https://github.com/tenequm/blackbox/pull/22)) ([0da2c90](https://github.com/tenequm/blackbox/commit/0da2c90da41cecca46cd187b550baad1b718fd62))
- run the full hardware suite in CI and automate releases ([#23](https://github.com/tenequm/blackbox/pull/23)) ([81906e1](https://github.com/tenequm/blackbox/commit/81906e14f53dd9dfd12671c24f9519cfef37f928))
  Blackbox releases are now cut by CI: merging the release PR builds,
  signs, notarizes, staples and publishes the DMG, signs the Sparkle
  appcast and bumps the Homebrew cask. `make test` runs the complete
  suite, hardware smoke tests included, on both a developer machine and a
  hosted runner.
- verify the Homebrew tap token in the release dry run ([#24](https://github.com/tenequm/blackbox/pull/24)) ([a474f41](https://github.com/tenequm/blackbox/commit/a474f419438c015a34d5a04a19b1526dc0c16b60))
  The release dry run now checks that the Homebrew tap token can actually
  push before a release depends on it, so a missing or expired token is
  caught on demand rather than at the cask step of a real release.
- ignore the Playwright CLI cache ([10d9184](https://github.com/tenequm/blackbox/commit/10d91841c11ec673a597358fa261a9f0e35a7df2))
- bump the build number without macOS-only tools ([bc8e1c2](https://github.com/tenequm/blackbox/commit/bc8e1c2f3b8f3303f8e98d69125d8dd43a01a8ac))
- port the release-pipeline lessons from glim-sh/cuttle ([0703dc9](https://github.com/tenequm/blackbox/commit/0703dc9eff0f460ac7e6efe32ef323eb4f10433f))
- run main's build-number script, not the release branch's ([7db35e9](https://github.com/tenequm/blackbox/commit/7db35e934726065e9300833717d52a923b1efa14))

**Full Changelog**: https://github.com/tenequm/blackbox/compare/v0.9.3...v0.9.4

## [0.9.3](https://github.com/tenequm/blackbox/compare/v0.9.2...v0.9.3) - 2026-08-20

### <!-- 2 -->Bug Fixes
- **aec:** run the blocking decode loop off the cooperative pool ([#19](https://github.com/tenequm/blackbox/pull/19)) ([2c118bb](https://github.com/tenequm/blackbox/commit/2c118bb61ed12e8f04af1c7c48ead7087271652d))
- **recorder:** survive display sleep during a recording ([#20](https://github.com/tenequm/blackbox/pull/20)) ([52caa1a](https://github.com/tenequm/blackbox/commit/52caa1a70e5ccaaa916983326bf7016fc6a131bd))

**Full Changelog**: https://github.com/tenequm/blackbox/compare/v0.9.2...v0.9.3

## [0.9.2](https://github.com/tenequm/blackbox/compare/v0.9.1...v0.9.2) - 2026-08-20

### <!-- 2 -->Bug Fixes
- **recorder:** stop SCStream rendering video at display refresh rate ([#18](https://github.com/tenequm/blackbox/pull/18)) ([b59dff8](https://github.com/tenequm/blackbox/commit/b59dff87de5a51855c819a5710de833ecc53ec9a))

### <!-- 5 -->Documentation
- rename Homebrew cask token to blackbox-recorder ([48451b2](https://github.com/tenequm/blackbox/commit/48451b2be5bf96bbf3afef035012cbb7489caf5c))
- **readme:** reframe intro around the workflow ([1ba1faa](https://github.com/tenequm/blackbox/commit/1ba1faa26f769a415da632c6d4efa4af9db2a895))

### <!-- 6 -->Chores
- **skills:** refresh installed skills ([a3a4312](https://github.com/tenequm/blackbox/commit/a3a431238bc5ac287a10d81ecd2c8a346bf08540))

**Full Changelog**: https://github.com/tenequm/blackbox/compare/v0.9.1...v0.9.2

## [0.9.1](https://github.com/tenequm/blackbox/compare/v0.9.0...v0.9.1) - 2026-07-03

### <!-- 2 -->Bug Fixes
- **recorder:** take channel 0 when mic input has a voice-processing layout ([db16745](https://github.com/tenequm/blackbox/commit/db16745e7e5ad9d1163866a7ae9fb2a02012b38c))
- **recorder:** add +20 dB makeup gain for voice-processing mic buffers ([2d7bfea](https://github.com/tenequm/blackbox/commit/2d7bfea3434a80cc549e4496953c4a6652711e0a))
- **ui:** scale menu bar level meter by dBFS so voice registers ([4775b70](https://github.com/tenequm/blackbox/commit/4775b70638d6063a83527c4ee81ecf1bf7b4961f))

### <!-- 5 -->Documentation
- **release:** add Homebrew tap bump, 403-agreement retry, and Gatekeeper verification to release-dmg skill ([0aac891](https://github.com/tenequm/blackbox/commit/0aac8919dfd11ce622c2edb836fe317320635d7a))

### <!-- 7 -->Other
- Merge pull request #14 from tenequm/fix/facetime-vp-mic-channel

fix(recorder): take channel 0 when mic input has a voice-processing layout ([421d6ab](https://github.com/tenequm/blackbox/commit/421d6ab71c1991a1ebf8345952240892a55ab625))

**Full Changelog**: https://github.com/tenequm/blackbox/compare/v0.9.0...v0.9.1

## [0.9.0](https://github.com/tenequm/blackbox/compare/v0.8.1...v0.9.0) - 2026-07-03

### <!-- 1 -->New Features
- **settings:** add Excluded Apps list to prevent unwanted auto-recording ([242756f](https://github.com/tenequm/blackbox/commit/242756fa40b8f380ad8c6535ab1186a7289bd11a))
- **transcription:** upgrade to Soniox stt-async-v5, drop English language bias ([f65344b](https://github.com/tenequm/blackbox/commit/f65344b8153a79352dbb431ee6c66a669d35d4c4))
- **settings:** configurable date prefix for recording names ([04ce436](https://github.com/tenequm/blackbox/commit/04ce436a0ed65dae0b0805b74ab216d22fb8f777))

### <!-- 2 -->Bug Fixes
- **build:** drop CLT framework search paths from test target ([aefe5b2](https://github.com/tenequm/blackbox/commit/aefe5b26a03329926541b22e6bd082bbd2289cf9))
- **monitor:** dedupe caller resolution and close stale-exclusion race ([9d9f02d](https://github.com/tenequm/blackbox/commit/9d9f02d9d6572a791cac8a48c8a8367a0ce31014))

### <!-- 5 -->Documentation
- add homebrew install and fix macOS requirement ([11ebb08](https://github.com/tenequm/blackbox/commit/11ebb0894d478fb44bfa8b62b7f126aea6a5a0f8))

### <!-- 6 -->Chores
- **skills:** vendor swift-macos + release-dmg in .agents/skills, symlink .claude/skills ([cb8a37f](https://github.com/tenequm/blackbox/commit/cb8a37fd66e5f7a1a75bc2ca97eac6bb5f3286f8))
- **monitor:** cover excluded-apps filtering ([84205d2](https://github.com/tenequm/blackbox/commit/84205d24cfcfd8d6fa638349d08db00fb7c156bf))

### <!-- 7 -->Other
- Merge branch 'main' into feat/excluded-apps

# Conflicts:
#	Sources/AudioMonitorSupport.swift ([5dd979d](https://github.com/tenequm/blackbox/commit/5dd979d21c637b22eb9128af70d00bdf22cfc380))
- Merge pull request #12 from mugoosse/feat/excluded-apps

feat(settings): add Excluded Apps list to prevent unwanted auto-recording ([9a55af6](https://github.com/tenequm/blackbox/commit/9a55af6f1e25b14880fe52dcd3f5fd8df976a056))

**Full Changelog**: https://github.com/tenequm/blackbox/compare/v0.8.1...v0.9.0

## [0.8.1](https://github.com/tenequm/blackbox/compare/v0.8.0...v0.8.1) - 2026-05-06

### <!-- 2 -->Bug Fixes
- **recorder:** prevent start/stop race, never leave 0-byte M4A, suppress auto-retry on stopped bundle ([283cb3c](https://github.com/tenequm/blackbox/commit/283cb3c5469532984e4ad89e6eb52c031b09e993))

**Full Changelog**: https://github.com/tenequm/blackbox/compare/v0.8.0...v0.8.1

## [0.8.0](https://github.com/tenequm/blackbox/compare/v0.7.0...v0.8.0) - 2026-04-24

### <!-- 1 -->New Features
- **audio:** revert system audio capture from CATap to display-wide SCStream (v0.8.0) ([eba5f16](https://github.com/tenequm/blackbox/commit/eba5f161488baf17d83d2c9514b80d76e81d5cb3))
- **audio:** implement D12 - layered mic recovery ([c75890d](https://github.com/tenequm/blackbox/commit/c75890d9870f4b2bf0fde212258c6fbac48c2e8c))

### <!-- 2 -->Bug Fixes
- **settings:** point permissions UI at Screen Recording pane for SCStream ([d8d0a67](https://github.com/tenequm/blackbox/commit/d8d0a67a47807cc22e64a62767981f6ab208be19))
- **audio:** PR review fixes - permission deep link, start/stop lifecycle, onboarding symmetry ([7521c8e](https://github.com/tenequm/blackbox/commit/7521c8ed4e117fbd87f0c616bf0d873948e3b5d2))
- **audio:** close PR #10 review items (D12 teardown, onboarding gate, minor polish) ([9a598d0](https://github.com/tenequm/blackbox/commit/9a598d09277906136346e5091ccc0092f08c1cb1))

### <!-- 4 -->Refactor
- **audio:** clean up trailing CATap residue and optimize SCStream hot path ([e14d307](https://github.com/tenequm/blackbox/commit/e14d3072e810c0e48d542e42a81b006f2c5a4fa2))
- **audio:** pass SCStream CMSampleBuffers through directly, write stereo system track (v0.6.0 parity) ([9d000ce](https://github.com/tenequm/blackbox/commit/9d000ce128b762446cdc5bfceffff6f59a06cf2b))
- **onboarding:** use live Screen Recording TCC preflight as skip trigger, drop audioRecordingGranted plumbing ([3ad1ff3](https://github.com/tenequm/blackbox/commit/3ad1ff392032b782d677360080cb79e4f5ec8178))

### <!-- 5 -->Documentation
- align specification with v0.8.0 SCStream revert ([2ce4001](https://github.com/tenequm/blackbox/commit/2ce400119334bbeb6b7fe48990f8b2c889ffee47))
- align CLAUDE.md architecture notes and CHANGELOG Unreleased with v0.6.0 parity ([fd5bea6](https://github.com/tenequm/blackbox/commit/fd5bea6d9f855560ee94a52ed552f5b49b032e06))
- **spec:** align diagram, D1/D8/D9, architecture evolution with v0.6.0 parity ([818f57a](https://github.com/tenequm/blackbox/commit/818f57a73ff774df610b0fbcee050dbbc8db1152))
- add D12 - layered mic recovery (AVAudioEngine notification + default-input listener + buffer-arrival watchdog) ([dcc27e9](https://github.com/tenequm/blackbox/commit/dcc27e9fe0f0e447d1d37c76d4c856892e824786))
- **changelog:** collapse Unreleased into v0.8.0 for release ([7014a56](https://github.com/tenequm/blackbox/commit/7014a561e8aa28d375a84ece32371255a7b1c9f4))

### <!-- 6 -->Chores
- **smoke:** remove CATap-era listener assertion and update stale comments ([202e40f](https://github.com/tenequm/blackbox/commit/202e40f9874bc24b19cb8aa236f949e5b6e8cb23))
- ignore .collab scratch dir and scheduled_tasks.lock ([d985146](https://github.com/tenequm/blackbox/commit/d98514688bb82d0eb76f9c921ca426df7469e72c))
- **smoke:** raise output-device-round-trip mic_age ceiling to 1500 ms ([44e0716](https://github.com/tenequm/blackbox/commit/44e0716000162721af183ed9ab71521167c6ee2d))

### <!-- 7 -->Other
- Merge pull request #10 from tenequm/feat/scstream-revert

feat(audio): v0.8.0 revert system audio capture from CATap back to display-wide SCStream ([6618be4](https://github.com/tenequm/blackbox/commit/6618be4ddda9c276d7df24d351e2e074df19225f))

**Full Changelog**: https://github.com/tenequm/blackbox/compare/v0.7.0...v0.8.0

## [0.7.0](https://github.com/tenequm/blackbox/compare/v0.6.0...v0.7.0) - 2026-04-17

### <!-- 1 -->New Features
- **recorder:** migrate system audio capture from SCStream to CATap ([535199c](https://github.com/tenequm/blackbox/commit/535199c0325307a2aa4e84cd9060d49f73780e0f))
- **recorder:** CATap migration, track alignment fix, and hardware smoke tests ([de8b824](https://github.com/tenequm/blackbox/commit/de8b824c43a8fefcc94b3e48d8c5c86ae57f171b))

### <!-- 2 -->Bug Fixes
- **recorder:** fill PTS gaps with silence to prevent track desync ([127be85](https://github.com/tenequm/blackbox/commit/127be85ae8165cc00eaabafe8d992e7c79a3bd6e))
- **recorder:** harden silence gap filling with clean ASBD and logging ([438e16b](https://github.com/tenequm/blackbox/commit/438e16bc2563308c1233cb500dff7ef12248df48))
- **recorder:** allow mic to start recording session independently ([a2384e0](https://github.com/tenequm/blackbox/commit/a2384e0f54cef7da54ee04a7aa29b502a92cab7f))
- **makefile:** chmod before bundle copy and xattr to fix permission denied errors ([af6e314](https://github.com/tenequm/blackbox/commit/af6e314f29f706bb32648e722a63c5bef8567ee7))
- **recorder:** revert force-48kHz aggregate rate; follow device rate instead ([7f02fa0](https://github.com/tenequm/blackbox/commit/7f02fa048a839ff32e6d5f2830f77038e063c858))

### <!-- 4 -->Refactor
- **audio:** adopt CoreAudio Swift wrappers + actor conversion for macOS 26.1+ ([1dca12b](https://github.com/tenequm/blackbox/commit/1dca12bc85f732e821056e7e2b1d38bc6a3b8572))
- **recorder:** address PR #7 review fixes ([09c0ab0](https://github.com/tenequm/blackbox/commit/09c0ab06ad03724f3a09426069e21ccce514fdb5))
- **recorder:** apply PR #7 review findings ([0020dc5](https://github.com/tenequm/blackbox/commit/0020dc5754233e63f7006c91869bf11e0e6667c7))

### <!-- 5 -->Documentation
- update spec for dual-SCStream and audio gap filling ([246ea3e](https://github.com/tenequm/blackbox/commit/246ea3eb8ad3b341d392335f1786bff7536b6139))
- **spec:** expand D8 with clock research, safety rules, and alternatives ([f7fe9c0](https://github.com/tenequm/blackbox/commit/f7fe9c01503af8f867b47645a8830900f8e9867e))
- **spec:** update architecture for CATap migration ([0e2b568](https://github.com/tenequm/blackbox/commit/0e2b568ef6ed03e9daf41f2b425a1c4189f9bb5e))
- **spec:** fix validation issues and add missing implementation details ([6451d4f](https://github.com/tenequm/blackbox/commit/6451d4fe221bb8c4ac78fdf79f42094342e846d0))
- **spec:** add architecture evolution section ([b783a22](https://github.com/tenequm/blackbox/commit/b783a22f9e2b3b2ef4904edae67e6188c1ac0d41))

### <!-- 6 -->Chores
- add switf-macos skill dependency ([5a49611](https://github.com/tenequm/blackbox/commit/5a49611403ea1eecbdb7ba015cd5d00f3896ffe6))
- add switf-macos skill dependency ([c73eee0](https://github.com/tenequm/blackbox/commit/c73eee00643c2fdf6f0f2b1ea77952ae7a33e461))
- remove collab files from feature branch ([cc1f533](https://github.com/tenequm/blackbox/commit/cc1f533e8c4b922cb3f8fa77d672717e550eda99))
- add edge case tests for pipeline and monitor ([8dafe43](https://github.com/tenequm/blackbox/commit/8dafe43da6b478ceb6ac96610d4cc642ee3ce07b))

### <!-- 7 -->Other
- Merge pull request #6 from tenequm/fix/audio-track-sync

fix(recorder): fill PTS gaps with silence to prevent mic/system track desync (re-merge) ([620ee21](https://github.com/tenequm/blackbox/commit/620ee2129e55b526ba076f1289540641c241e017))
- Merge branch 'main' into refactor/catap-migration ([a853420](https://github.com/tenequm/blackbox/commit/a85342021a6ca225d86a22d4691450c3cc2fa16f))
- Merge pull request #7 from tenequm/refactor/catap-migration

refactor(audio): CoreAudio Swift wrappers + actor conversion (macOS 26.1+) ([ddaa843](https://github.com/tenequm/blackbox/commit/ddaa84394e8e183b6922e3a594f3eaf487f9164e))

**Full Changelog**: https://github.com/tenequm/blackbox/compare/v0.6.0...v0.7.0

## [0.6.0](https://github.com/tenequm/blackbox/compare/v0.5.1...v0.6.0) - 2026-04-04

### <!-- 1 -->New Features
- **recorder:** dual-SCStream recording architecture ([539195c](https://github.com/tenequm/blackbox/commit/539195c64e2bde7bfea3c06f1e324acddadc66a3))

### <!-- 3 -->Performance
- **recorder:** fuse peak tracking into publishAudioLevel, fix docs ([60f5f22](https://github.com/tenequm/blackbox/commit/60f5f22c9de5f497682725f2aabe48a471812677))

### <!-- 7 -->Other
- Merge pull request #4 from tenequm/feat/dual-scstream

feat(recorder): dual-SCStream recording architecture ([f67e795](https://github.com/tenequm/blackbox/commit/f67e79567a7dfef4334e358f26de21e4a628d6a7))

**Full Changelog**: https://github.com/tenequm/blackbox/compare/v0.5.1...v0.6.0

## [0.5.0](https://github.com/tenequm/blackbox/compare/v0.4.3...v0.5.0) - 2026-03-13

### <!-- 1 -->New Features
- **capture:** per-app audio capture with display-wide fallback ([877372f](https://github.com/tenequm/blackbox/commit/877372fba5fe53e80206e8f5a690821d8ea236d4))

### <!-- 2 -->Bug Fixes
- **recorder:** bulletproof mic capture against Krisp/device-switch crashes ([e91a71d](https://github.com/tenequm/blackbox/commit/e91a71dba54c93e84e51e4f1999cd6b59816ecb0))

### <!-- 4 -->Refactor
- **aec:** stream AEC processing chunk-by-chunk instead of batch ([f3e4002](https://github.com/tenequm/blackbox/commit/f3e4002017c87341cf8873f08d4f76c2d4b9ead4))

### <!-- 5 -->Documentation
- add app icon and screenshot to README ([3586d74](https://github.com/tenequm/blackbox/commit/3586d740f2a025e6f8a01a39b9210f6070f22ea0))

### <!-- 6 -->Chores
- add .swiftpm/ to gitignore ([d1fa2a5](https://github.com/tenequm/blackbox/commit/d1fa2a599d829218d2250cfe03be6ff5f6747abb))

### <!-- 7 -->Other
- Merge pull request #1 from tenequm/feat/per-app-audio-capture

Per-app audio capture with display-wide fallback ([3f832c8](https://github.com/tenequm/blackbox/commit/3f832c8130b472a6e218d7b498cdf1b30d3c3c7d))

**Full Changelog**: https://github.com/tenequm/blackbox/compare/v0.4.3...v0.5.0

## [0.4.0](https://github.com/tenequm/blackbox/compare/v0.3.0...v0.4.0) - 2026-03-11

### <!-- 1 -->New Features
- AVAudioEngine mic capture, waveform visualization, architecture simplification ([bf37850](https://github.com/tenequm/blackbox/commit/bf37850db8cedb1fa32a4b1fc85b9c7fd3e1e185))
- **aec:** add DTLN-aec echo cancellation post-processing with UI controls ([4bbec7a](https://github.com/tenequm/blackbox/commit/4bbec7a0b61d31fa3fc23cf74a003ef2476b1909))

### <!-- 5 -->Documentation
- add audio architecture specification and Azayaka acknowledgment ([502aff1](https://github.com/tenequm/blackbox/commit/502aff10a0cbf13ef8416fa6e582f51c483fccb9))
- **spec:** add D7 - VPIO incompatible with SCStream system audio ([351886b](https://github.com/tenequm/blackbox/commit/351886b0efa6cd67eaae1a1a8c37026fa35b33ba))

### <!-- 6 -->Chores
- switch license from Apache 2.0 to GPL v3 ([bd9cfdf](https://github.com/tenequm/blackbox/commit/bd9cfdf63c3ca4c40206a47c299ba4f1f0354616))

**Full Changelog**: https://github.com/tenequm/blackbox/compare/v0.3.0...v0.4.0

## [0.3.0](https://github.com/tenequm/blackbox/compare/v0.2.0...v0.3.0) - 2026-03-10

### <!-- 1 -->New Features
- per-process mic detection, transcription, and recordings UI ([01d18b4](https://github.com/tenequm/blackbox/commit/01d18b48176f7a1b02226d875441a8c6ec76e201))
- .blackbox bundle format, HUD notifications, audio metering, production hardening ([72ebfc2](https://github.com/tenequm/blackbox/commit/72ebfc2b2a5ebe70ddb964031d757dd89ca30b94))
- dual-track capture with auto-mix, MP3 export, transcription improvements ([7e15dca](https://github.com/tenequm/blackbox/commit/7e15dcad2f04b30241ed945a97873123f020d6df))

### <!-- 2 -->Bug Fixes
- harden recording safety, mic detection, and build pipeline ([2d03326](https://github.com/tenequm/blackbox/commit/2d0332646d35a9f6e96c4db6150df28f0f33762e))
- **export:** replace broken MP3 export with M4A single-track export ([c787927](https://github.com/tenequm/blackbox/commit/c787927542114bf2dead39640b9473627ea4d572))

### <!-- 5 -->Documentation
- add CHANGELOG.md following keepachangelog format ([4206b8d](https://github.com/tenequm/blackbox/commit/4206b8df81fc378491f0575974180d657cad0735))

**Full Changelog**: https://github.com/tenequm/blackbox/compare/v0.2.0...v0.3.0

## [0.2.0](https://github.com/tenequm/blackbox/releases/tag/v0.2.0) - 2026-03-09

### <!-- 1 -->New Features
- initial Blackbox implementation ([31dc08b](https://github.com/tenequm/blackbox/commit/31dc08b8c34c722fb5123d25811e581e64f47bbf))
- app icon, notifications, settings UX, Telegram support, stable signing ([a487663](https://github.com/tenequm/blackbox/commit/a487663487aa1c9070eb0db8b8bda5f9211850af))
- add Sparkle auto-update support ([17a37d5](https://github.com/tenequm/blackbox/commit/17a37d5537641f16bffacdea3cc8180a904c8a12))
- add structured logging with os.Logger + file sink ([4d69c19](https://github.com/tenequm/blackbox/commit/4d69c192558b6e8c7f0c3f8f5f500299295fef69))
- UX overhaul with onboarding, recording HUD, settings redesign, and concurrency fixes ([3a7c25c](https://github.com/tenequm/blackbox/commit/3a7c25c760e6058889b3b9e987fb58cee08f0685))
- bulletproof audio recording with auto-recovery and device following ([1feb6ac](https://github.com/tenequm/blackbox/commit/1feb6accc8f18df2bcb3b87bba3032761561e5ed))
- mic-based detection, simplified menu, HUD improvements ([e7aca3c](https://github.com/tenequm/blackbox/commit/e7aca3c8432e05f3e67c22e62459d13f5d766311))

### <!-- 2 -->Bug Fixes
- onboarding flow, data races, and UX polish ([5a717a5](https://github.com/tenequm/blackbox/commit/5a717a5fd76042bd209e7867c1a6acb99fdb0b97))
- mic device targeting, permission UX, menu state priority, and race conditions ([02d1712](https://github.com/tenequm/blackbox/commit/02d1712c97bca5c8518ee995607ca2e7c4ad563b))
- live elapsed timer, menu layout, and settings resizability ([debe3b0](https://github.com/tenequm/blackbox/commit/debe3b03f1c698a01eee10208fef774eb05e3eb6))

### <!-- 5 -->Documentation
- add README with setup and install instructions ([d30e2f6](https://github.com/tenequm/blackbox/commit/d30e2f694e955f5d3f18d7b2114cdb6c7aea1c15))
- update CLAUDE.md for new save path, menu label, and resilience architecture ([80449a0](https://github.com/tenequm/blackbox/commit/80449a0c159b2b3d33953c12318e02afa4233fe2))

### <!-- 6 -->Chores
- Developer ID signing, deep-sign Sparkle, simplify README ([b719650](https://github.com/tenequm/blackbox/commit/b71965061c52b86556826f5b943a69c4bc004ab4))
- bump version to 0.2.0, add release pipeline ([6f0284c](https://github.com/tenequm/blackbox/commit/6f0284c8ccb9b71bc464997aa51a8058f3daa867))
