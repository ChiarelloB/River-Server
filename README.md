# River Server

BeamMP server for **BeamNG.drive 0.39** running the **RLS Career Overhaul** career with **RiverLife**, a player-driven
economy: classifieds with real photos, GPS visits, player-owned car dealerships and workshops with staff and NPC
customers, gigs, "for sale on the street", the River FIPE price table and the RiverOS computer. Every player keeps their
own career; the RiverLife economy is shared on the server. RiverLife follows the game language (English, Español,
Русский, Português); the setup scripts print in Portuguese and this page is their English guide.

No car mods. Players only need BeamNG.drive 0.39 and BeamMP: on join the server hands them RiverLife, RLS and,
optionally, the River Highway map with its fixes.

## Quick start (Windows)

1. Download **River-Server-v1.1.1.zip** from [Releases](../../releases/latest) and extract it.
2. Run **Iniciar-Servidor.cmd**. The first time it asks for the map (West Coast USA, or River Highway: 1.8 GB map with the
   *riverpack* fixes built in) and whether to hand RLS to the players (recommended), downloads the official BeamMP-Server 3.9.3
   and the chosen optional files (SHA-256 checked) and starts the server.
3. Give your friends the address it prints (`IP:30814`); they join with BeamMP's Direct Connect.

Forward port 30814 (TCP and UDP) for friends outside your network, or use a gaming VPN (Radmin VPN, Tailscale,
ZeroTier). To be listed in BeamMP, put your key from <https://keymaster.beammp.com> in `Servidor\servidor.json`.

NPC private sellers (6 by default) park their cars for sale in house driveways and car parks, never on the street.
Change how many, or turn them off with `0`, with `"npcPrivateSellers"` in `Servidor\servidor.json` and restart
the server with `Iniciar-Servidor.cmd` (without the scripts: the same key in
`Servidor\Resources\Server\RiverLife\config.json`). Players' dealerships and workshops have their own NPC customers,
switched on and off by their owners in RiverOS.

Full guide (Portuguese): [LEIA-ME.md](LEIA-ME.md). Credits: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

---

# River Server (português)

Servidor BeamMP com a carreira do RLS e o RiverLife. Baixe o **River-Server-v1.1.1.zip** em *Releases*, extraia e rode
**Iniciar-Servidor.cmd**: ele pergunta o mapa (West Coast USA ou River Highway) e se entrega o RLS aos jogadores, baixa o
que precisa e sobe o servidor. Guia completo em [LEIA-ME.md](LEIA-ME.md).
