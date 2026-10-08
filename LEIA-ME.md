# River Server 1.0.0

Servidor BeamMP com a carreira do **RLS Career Overhaul** e o **RiverLife**: classificados com fotos, visitas pelo GPS,
lojas de carros e oficinas dos jogadores com funcionários e clientes NPC, bicos, "vende-se na rua", Tabela FIPE do
River e o PC RiverOS. Cada jogador tem a sua carreira; a economia do RiverLife é compartilhada no servidor.

Não traz mods de carros. Os jogadores só precisam do **BeamNG.drive 0.39** e do **BeamMP**: ao entrar, o servidor
entrega a eles o RiverLife, o RLS e (se você escolher) o mapa River Highway com as correções.

## Instalar e rodar (Windows)

1. Baixe **River-Server-v1.0.0.zip** em *Releases* e extraia numa pasta (ex.: `C:\RiverServer`).
2. Dê dois cliques em **Iniciar-Servidor.cmd**. Na primeira vez ele pergunta:
   - **Mapa**: West Coast USA (vem com o jogo) ou River Highway (baixa o mapa, 1,7 GB, e o *riverpack* com as
     correções de árvores, guard-rails, materiais e entregas).
   - **RLS**: se entrega o RLS Career Overhaul aos jogadores (recomendado: é ele que dá a carreira).

   O script baixa o **BeamMP-Server 3.9.3 oficial** (GitHub do BeamMP) e os opcionais escolhidos desta release,
   confere o SHA-256 de cada arquivo e sobe o servidor. A janela preta que abre é o console do servidor.
3. Passe para os amigos o endereço que aparece (`IP:30814`). Eles entram pelo BeamMP (*Direct Connect*).

Para trocar o mapa ou os opcionais depois: pare o servidor e rode **Configurar.cmd** (o que for desligado fica
guardado em `Servidor\opcionais-desligados`, sem baixar de novo ao religar).

## Amigos fora da sua casa

Libere a porta **30814 TCP e UDP** no roteador, ou usem a mesma VPN de jogos (Radmin VPN, Tailscale, ZeroTier) e passe
o endereço dela.

## Aparecer na lista do BeamMP (opcional)

Crie a chave em <https://keymaster.beammp.com> (login com Discord), cole em `Servidor\servidor.json` no campo
`"authKey"` e troque `"private"` para `false`. Sem chave o servidor é privado e o pessoal entra pelo endereço.

## Console do servidor

- `rl status` — jogadores, anúncios, lojas e oficinas.
- `rl backup` — cópia do estado do RiverLife.
- `rl give <nome> <dólares>` — dinheiro para um jogador.
- `admin add <conta BeamMP>` — admin (no chat do jogo: `/kick`, `/ban`, `/whitelist`, `/aviso`, `/ajuda`).

Os dados do RiverLife ficam em `Servidor\Resources\Server\RiverLife\data`. Para atualizar, baixe a release nova e
copie por cima com o servidor parado (os dados e o `servidor.json` ficam).

## Arquivos

| Arquivo | Para quê |
|---|---|
| `Iniciar-Servidor.cmd` | Configura na primeira vez e sobe o servidor. `-Mapa river_highway` troca o mapa. |
| `Configurar.cmd` | Escolhe o mapa e os opcionais e baixa o que faltar. |
| `Parar-Servidor.cmd` | Encerra o servidor desta pasta. |
| `Servidor\servidor.json` | Nome, porta, vagas, mapa, chave do BeamMP. |
| `opcionais.json` | Endereços e SHA-256 do BeamMP-Server e dos opcionais. |

Versão 1.0.0 (RiverLife d79389a). Créditos de terceiros em `THIRD_PARTY_NOTICES.md`.
