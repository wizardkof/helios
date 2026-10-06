# P06 — fronteiras de Package após a .313

As duas fronteiras da .313 foram corrigidas e atravessadas na única CI da 22.22.314.0. Driver Release/Debug e componentes 5/5 passaram. Os dois Packages concluíram assembly/test signing, schema nativo 8/8 e extração/ZIP 69/69, mas foram cancelados automaticamente pelo limite de 30 minutos durante a auditoria final. FINAL_PACKAGE=PARTIAL_NO_QUALIFIED_EXPORT. A .314 permanece congelada, sem retry.

Autoridade: instrução do proprietário no attachment `a4074c62-cf15-4f68-8ad9-e6b7e77797cf` e relatório da fase anterior em `.fullstack/artifacts/p06/component-frontiers-20261005/REPORT.md`.

## Baseline preservado

A `.313` conserva `COMPONENTS=PASS_5_OF_5`, HEAD `8be68221360e2ae59f92b8598da9ed3d5eb0ccb9`, fingerprint `6982a610df4ebd1d52998fe18ac35d81d43cfad97c0141c3198bdbef833904a1` e run `37392622277`, attempt 1. Seus dois Package falharam separadamente: Release recebeu HTTP 503 ao adquirir o manifesto do nightly; Debug recusou a data do INF e substituiu a exceção interna. A indisponibilidade observada não prova defeito de pin, source ou runner. Debug instalou o mesmo nightly na mesma execução.

Os snapshots `.310` a `.313` conservam HEAD, metadata e limpeza dos arquivos rastreados. Os 16 ZIPs originais da `.313` foram rehashados contra os digests históricos da API. O INF Debug original tem SHA-256 `e4182ed44ed73dd2063fbf698b049a8ee8dc5e55832d9f37abfc0135fb8da887`, tamanho 8609 bytes, data `10/06/2026`, comprimento 10 e versão `22.22.313.0`. Proveniência completa: `real-inf-provenance.json` e `historical-313-original-archives.json`.

## Parser: prova e correção

O primeiro controle, run `37415126735`, executou PowerShell 7.6.6 Core x64, InvariantCulture e DateTimeStyles.None antes da mudança de produção. A expressão histórica falhou tanto na literal quanto no valor extraído pela regex do INF real. A única mudança de argumento para `String[]` passou nos dois casos. O trace MethodInvocation mostra que o array histórico `System.Object[]`, com elementos `System.String`, selecionou o overload de formato único. O controle preserva MethodInvocationException, mensagem, InnerException System.FormatException, FullyQualifiedErrorId, ScriptStackTrace e os tipos efetivos.

Causa qualificada: `POWERSHELL_PARSEEXACT_FORMAT_ARRAY_BINDING`. O parser de produção agora fornece `String[]`, mantém ParseExact e a cultura invariável e preserva o erro principal com a exceção original encadeada e receipt `driver-date-diagnostic.json`. A matriz nativa executa o bloco real de produção: três datas válidas passam; mês 13, dia 32, ISO, string vazia e versão divergente falham. Resultado: 8/8.

## Rust: aquisição finita com o mesmo pin

O pin continua `nightly-2026-07-14`. A implementação oficial do rustup 1.29.1 distingue aquisição do manifesto e downloads de componentes. O controle com o executável real observou somente uma requisição de manifesto HTTP 503 mesmo com `RUSTUP_MAX_RETRIES=10`; portanto esse env sozinho não fecha a falha histórica. Fontes oficiais: [manifestation.rs](https://github.com/rust-lang/rustup/blob/1.29.1/src/dist/manifestation.rs), [download.rs](https://github.com/rust-lang/rustup/blob/1.29.1/src/dist/download.rs). Commit auditado `d95a37b6ab92cc1e455d1576039333c97ca3e2c5`, hashes em `rustup-retry-source-provenance.json`.

O Package define dez retries de download de componente e no máximo dez retries adicionais da mesma invocação de instalação para manifesto HTTP 502/503/504. O wrapper não repete workflow/candidata, não troca mirror ou versão e não repete erros de componente após o limite interno do rustup. Após instalação, verifica lista de toolchains e as versões exatas de rustc/cargo. Os checks Package pré e pós também verificam rustup, rustc, cargo e o budget.

Os seis casos nativos usam o rustup real. A injeção de falhas ocorre apenas no loopback do controle, com homes isolados e bytes originais adquiridos do servidor oficial. Casos: manifesto persistente sem wrapper; instalação imediata; 503 seguido de sucesso; manifesto persistente até 11 invocações e FAIL; 404 sem retry; componente persistente até 11 downloads e FAIL. Não há PASS simulado de instalação.

O controle intermediário `37415414514` mantém seu FAIL: instalou a toolchain exata, mas o teste de recuperação revelou a mensagem real lowercase `http request returned an unsuccessful status code`. O reconhecimento foi corrigido e testado. Seus ZIP, erro e roundtrip permanecem preservados; o resultado não foi promovido.

## Preflight final e revisão

Run `37416159314`, attempt 1, SHA `ee223ef91d46c449890c02c9d35aa4dc2d1e81ce`: três jobs SUCCESS, Rust 6/6, DriverVer 8/8 e três roundtrips nativos PASS. Release e Debug compilaram seus próprios installers e executaram o bloco contíguo real do Assemble para recursos/versionamento dos cinco PEs, INF, data e arquiteturas. Os inputs mantêm a identidade histórica `.313`; a execução e o installer de controle possuem proveniência separada. Resultado `PASS_PRODUCTION_DRIVER_GATE_BLOCK`, explicitamente diferente de signing/assembly completo ou release.

Os hashes do Assemble correspondem ao mesmo commit: LF Linux `47e4d488c0e5bbb2bca2eb10129fec3321aa8ca327f7d6885f70b6b68d5cc990`; CRLF do checkout Windows `8e2b146339c38f3edeb2d31e2a001c8d93de7413babbfa100526e8d0c90ceb9f`, igual aos dois receipts nativos. Nenhum artifact foi reordenado ou reescrito.

Os controles completos anteriores `37415594584` também passaram. O total de oito ZIPs originais novos foi preservado com API digest, CRC e bytes extraídos. Suites portáveis: 79 testes, 75 PASS e quatro SKIP exclusivos de Windows; candidate-version 15/15. As mesmas suites passaram na árvore congelada. Revisão independente e follow-up PASS, sem Critical/Important; hashes revisados em `independent-review.json`. Scan relacionado permanece restrito às superfícies Package de ParseExact/DriverVer/arrays de método/bootstrap Rust.

## Candidata e execução de produto

O ledger remoto só foi consultado após controles, testes e revisão PASS. Versão `22.22.314.0`, fingerprint `a034c3d1660540ab717868444c8882ca7883fae485be6955d16ff366daf1babe`, frozen HEAD `d03d79ebec6d857d141469d197e11c04097c4d75`, source base `d3e2a5a17b273190e753aa68d2997d780c108aaa`. Reserva `refs/helios/candidate-reservations/22.22.314.0`, digest `36a0b7d002d4f721ffc2bf086d069a071367b2a871530b696a734cc321222b01`. O último código qualificado é `ee223ef91d46c449890c02c9d35aa4dc2d1e81ce`; o commit seguinte contém apenas documentação, e o freeze altera somente version/reservation/history metadata. Os hashes dos arquivos Package continuam iguais aos controles revisados.

Run de produto [37417032761](https://github.com/wizardkof/helios/actions/runs/37417032761), attempt 1, `infrastructure_only=false`, todos os flags focais false. A consulta da branch remota confirma um único dispatch, sem retry. A execução terminou CANCELLED em 2026-10-06 às 10:21:48 UTC. Nenhum PASS da .313 substitui prova desta candidata.

Python nativo: 78/79 PASS, um SKIP, candidate-version 15/15. DXVK: 9/9 casos OK. Driver Release/Debug: complete PASS, fingerprints pré/pós exatos, símbolos PASS e roundtrips PASS. Cada profile registra quatro execuções WDK privadas e três host com exit 0. Compatibility, Loaders, Mesa x64, Mesa x86 e OpenCL têm resultado primário PASS, coleta PASS e fingerprints pré/pós conferidos. OpenCL registra 7/7 fases PASS, pins CLVK/clspv/LLVM exatos e zero processos ativos após cleanup; PHASE_BUILD durou 11112,838 segundos. Receipts: `product-driver-qualification.json` e `product-components-qualification.json`.

## Package: gates atravessados e primeira fronteira nova

Release e Debug adquiriram exatamente o nightly qualificado na primeira tentativa, com RUSTUP_MAX_RETRIES=10 e sem fallback. Compilaram installers distintos. O gate DriverVer passou com `2026-10-06` e versão .314. Os steps Assemble and test-sign bundle concluíram SUCCESS nos dois jobs, incluindo geração INF/CAT e test signing. Os receipts de scripts realmente extraídos comprovam schema 8/8 em PowerShell 5.1 x64, sem execução de Setup ou alteração do estado instalado. Verify-CIPackage concluiu a extração fresca e a comparação exata staging/payload/ZIP: 69/69 arquivos por configuração, CRC e identidade Setup/ZIP PASS. Esses são resultados nativos preservados; os binários finais não foram exportados para repetir a extração localmente.

As annotations dos dois jobs declaram literalmente o limite de execução de 30 minutos excedido. Ambos começaram às 09:51:14 UTC e terminaram CANCELLED às 10:21:46/47 UTC. O step interrompido foi Independent final package extraction and native audit. A conclusão integral de Audit-CIPackage permanece NOT_PROVEN; não há receipt de auditoria offline completa, toolchain pós-gate, fingerprint pós-gate ou QUALIFICATION_REPORT. O upload e o roundtrip do artifact final foram SKIPPED. A causa interna da duração da auditoria permanece NOT_PROVEN; não se atribui defeito a signing, Rust, source ou runner por inferência. Não houve cancelamento manual desta sessão, edição da candidata ou retry.

Identidades declaradas pelos receipts nativos, sem disponibilidade local dos binários finais:

| Configuração | Setup SHA-256 | ZIP SHA-256 |
|---|---|---|
| Release | `436389409a5ffd98b1eee14cc09c5590f567b8bb93213a5914da43137682c5a0` | `cee8b1d66ca9a2fa0a3c8b7fa2f164a32448026462269a72059fca0a45793bf5` |
| Debug | `162a25fd8e4c4c8195e2da132748ae8bdf2d4955640accd48c620cd163ffbfee` | `c09993cd6d8e5d66c64b1edd62a3223c6bb57fe2fd97d2d959604667b7ea1bfa` |

Resultado: `PACKAGE_RELEASE=CANCELLED_JOB_TIME_LIMIT_30_MINUTES`, `PACKAGE_DEBUG=CANCELLED_JOB_TIME_LIMIT_30_MINUTES`, `FINAL_PACKAGED_SCHEMA=PASS_NATIVE_8_OF_8_RELEASE_AND_DEBUG`, `FINAL_PACKAGE=PARTIAL_NO_QUALIFIED_EXPORT`. A .314 fica congelada nessa nova fronteira. Detalhes: `product-package-partial-qualification.json`, `package-cancellation-provenance.json`, annotations e os logs originais dos jobs.

## Preservação e fechamento

Foram preservados 40 ZIPs originais no escopo desta entrega: 16 históricos da .313, oito controles novos e 16 artifacts de produto .314. API digest, CRC, bytes extraídos e índices de arquivos PASS. Os oito logs de jobs executados da .314 estão disponíveis. Todos os 16 artifacts efetivamente publicados pela .314 possuem roundtrip nativo PASS; isso não inclui os dois artifacts finais de Package, que não foram publicados. Os receipts dos dois Packages preservam resultado primário cancelled e coleta/roundtrip PASS separadamente.

O verificador local conserva FAIL_ORDER_ONLY para sete artifacts binários de produto, enquanto o mapa exato de arquivos/tamanhos/hashes passa; nenhum artifact foi reordenado. Source-lock remoto pós-run PASS. Os cinco snapshots .310–.314 conservam HEAD, metadata e estado rastreado limpo; os 16 ZIPs da .313 continuam com os hashes originais. Campos completos em `classification.json` e `STATUS.txt`; inventário de entrega em `delivery-manifest.json` e índices por run. Nenhuma nova reserva ou CI foi iniciada após a primeira fronteira nova.

## Limites preservados

O ordered verifier Linux histórico permanece `FAIL_ORDER_ONLY`, separado do mapa exato de arquivos/tamanhos/hashes e dos roundtrips nativos PASS. A preservação não altera artifacts para satisfazer diferenças de ordenação WindowsPath/PosixPath.

WinBoat, build local de produto, deploy, reboot e runtime NOT_RUN; GitHub Release NO. HISTORICAL_310_ROOT_CAUSE, BLACK_SCREEN_FIXED, DEVICE_LOSS_ORIGIN, DEADLOCK_IN_ORIGINAL_CAPTURE, SSH_POST_REBOOT_CAUSE e EXTRA_CONTAINER_RESTART_CAUSE permanecem NOT_PROVEN. Nenhum arquivo `*.inx`, `docs/archive/**`, `Logs/` ou source sujo original foi alterado.
