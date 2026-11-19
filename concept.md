# Agent ID Hackathon — Konsep Entry

- **Hackathon:** Binance Wallet × BNB Chain, total hadiah 60.000 USDC
- **Submission:** 18 Nov 2026 15:00 WIB → **9 Des 2026 15:00 WIB** (20 hari lagi)
- **Review:** internal 9–17 Des, publik 17–20 Des; hasil di Binance Square ≤14 hari kerja setelah review
- **Aturan kunci:** 1 proyek per peserta (hanya pengajuan pertama dinilai); deploy di BNB Chain; verifikasi source di BscScan; kode open-source; integrasi Agent ID nyata; proyek lama boleh ikut
- **Penilaian:** Innovation 30%, UX 30%, Community Popularity 20%, Technical 20% + data interaksi on-chain pemegang Agent ID
- **Pengumuman:** https://www.binance.com/en/support/announcement/detail/95f5dbe0ea674a48a739b59e046648bf

## Fakta teknis terverifikasi (19 Nov 2026)

- **Registry Agent ID:** `0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F` (SPACE ID Agent ID, symbol `AI`, bytecode 8.756 byte). `balanceOf(0xE5B708CB…B4DbA) = 1` — bjorka01 terkonfirmasi on-chain.
- **Pola integrasi terbukti:** `balanceOf(msg.sender) > 0` pada registry = gate "pemegang Agent ID". Dipakai UNITS, Coracle, Oathbots.
- **Bukan ERC-721 standar:** `totalSupply()`, `tokenOfOwnerByIndex()`, `tokenURI()` semua gagal — registry ini implementasi khusus (soulbound, non-enumerable). Jangan andalkan fungsi ERC-721 di luar `balanceOf` (+ `name`/`symbol`).
- **Resolusi nama → alamat: TERVERIFIKASI on-chain 19 Nov 2026** (fase 1, dibuktikan parent dengan eth_call live): `ownerOfHandle(string)` selector `0x1da94fb4` (nama tanpa `.ai` → alamat; tak terdaftar → `0x0`); `handleOf(address)` selector `0xc50a1514` (alamat → nama; tanpa handle → `""`). tokenId = `uint256(keccak256(handle))` — bukan nomor urut (itu sebabnya probe `tokenURI(1)` gagal). Kontrak hanya memakai `balanceOf` sebagai gate (paling murah gas); frontend resolve nama via `eth_call` gratis.
- **Saldo BNB wallet:** **0,00316 BNB** (~$1,83). Deploy terukur persis 1.706.428 gas ≈ **0,001706 BNB @ 1 gwei** — cukup @ ≤1,8 gwei + tx uji; @ 3 gwei deploy saja melebihi saldo. Rekomendasi: top-up ~0,01 BNB sebagai pengaman sebelum deploy mainnet.
- **Biaya interaksi pengguna (dikoreksi fase 1):** gas-only, checkIn ~53k gas (~0,000053 BNB @ 1 gwei), attest ~108k (~0,000108), claimQuest ~51k (~0,000051) — kisaran ~0,00005–0,00018 BNB/aksi @ 1 gwei (~$0,03–0,10). Tetap murah, tapi 5–10x lipat dari estimasi awal.

## Lanskap kompetisi (riset 19 Nov)

Ruang "NFT mint ber-gating Agent ID" SUDAH RAMAI — ketiganya live di BSC:
- **UNITS** (units-agentic.fun): 10.000 robot, mint hanya pemegang .ai, token + NFT + bonding curve.
- **Coracle Agents** (coracle-agents.pages.dev): 10.000 pixel captain, 2 pertama gratis, mint gating `balanceOf` registry.
- **Oathbots** (oathbots.online): 10.000 bot on-chain, Oath Pass gratis untuk pemegang .ai, arena duel + forge.

Implikasi: konsep "satu lagi NFT mint ber-gating Agent ID" akan lemah di Innovation (30%) dan harus bersaing memperebutkan pemegang Agent ID yang sama. Entry kita harus menawarkan mekanik yang BERBEDA dan memberi alasan bagi pemegang Agent ID untuk kembali berinteraksi BERULANG (metrik interaksi menghitung jumlah tx, bukan sekali mint).

## KONSEP A (REKOMENDASI): Agent Quests — papan quest harian on-chain untuk pemegang Agent ID

**Ide dalam satu kalimat:** Duolingo-nya agen — pemegang Agent ID menyelesaikan quest harian gratis (gas-only) di BSC, membangun streak, XP, dan reputasi on-chain yang bisa dilihat siapa pun.

**Mekanik inti (semua interaksi gas-only, tanpa biaya proyek):**
1. **Daily check-in** — 1 tx/hari, membangun streak (dicatat on-chain: `lastCheckIn`, `streak`). Streak putus bila sehari absen.
2. **Attestation antar-agent** — pemegang Agent ID bisa memberi vouch/reputasi ke Agent ID lain (1 tx, rate-limited, mis. maks 3/hari, tidak bisa vouch diri sendiri). Membangun graf kepercayaan antar-agent — ini identitas + reputasi yang sesungguhnya.
3. **Quest mingguan** — tantangan sederhana yang berubah tiap minggu (mis. check-in 5 hari, vouch 3 agent berbeda, capai streak 7). Selesai = XP + badge.
4. **XP, level & leaderboard** — semua dihitung dari event on-chain; leaderboard mingguan + all-time di frontend.
5. **Achievement badges** — catatan on-chain (bukan NFT terpisah, hemat gas; atau soulbound badge bila anggaran gas memungkinkan).

**Kenapa ini menang di kriteria:**
- **Innovation (30%):** bukan mint ke-4; ini *reputasi & engagement layer* untuk identitas agent. Attestation antar-agent adalah kasus nyata "identity" yang diminta pengumuman. Quest harian = mekanik retensi yang belum ada di ekosistem Agent ID.
- **UX (30%):** 1 klik per quest, tanpa biaya selain gas; frontend bersih (leaderboard, profil, streak); plus `skill.md` agar agen AI bisa bermain lewat CLI mereka sendiri (pengguna sebenarnya adalah agen — pola yang dipakai Oathbots/Coracle).
- **Community Popularity (20%) + data interaksi:** quest HARIAN berarti 1 pengguna = banyak tx selama periode submission (bukan 1 tx seperti mint). Gratis = hambatan masuk nol. Dipromosikan lewat Binance Square (kita sudah publish di sana), X (dia posting sendiri), dan periode public review hackathon.
- **Technical (20%):** 1 kontrak ramping + frontend statis + test suite + BscScan verify + open-source GitHub. Sederhana = bisa selesai tepat waktu dan diuji tuntas.

**Arsitektur:**
- `AgentQuests.sol` (BSC mainnet): registry Agent ID sebagai konstanta; `checkIn()`, `attest(address agent, string reason)`, `claimQuest(questId)`, view `profile(address)` (streak, XP, level, attestations), event untuk semua aksi. Tanpa owner withdrawal; tanpa token.
- Frontend: situs statis (Netlify, pola sama seperti situs AVSC) — board quest, leaderboard, profil. Baca on-chain langsung (tanpa backend).
- `skill.md`: instruksi untuk agen AI (Binance Agentic Wallet CLI / baw) agar bisa check-in & attest sendiri.
- Repo GitHub publik (open-source), Foundry tests, BscScan verification.

**Risiko:** Popularity tetap tantangan (tanpa audiens awal) — mitigasi: gratis + harian + promosi Square/X + periode public review. Resolusi nama .ai **TERVERIFIKASI on-chain 19 Nov 2026** (ownerOfHandle `0x1da94fb4`, handleOf `0xc50a1514) — frontend menampilkan nama .ai; kontrak hanya memakai `balanceOf` sebagai gate.

## KONSEP B (alternatif): Agent Escrow — pasar jasa mikro antar-agent

Pemegang Agent ID mem-posting penawaran jasa mikro (mis. riset, review kode, penulisan); pemberi kerja mengunci BNB di escrow; penyelesaian dikonfirmasi → dana cair. Kasus nyata payments + identity + access control. Innovation tinggi, TETAPI: butuh pasar dua sisi (penjual + pembeli) dalam 20 hari tanpa audiens, perlu mekanisme sengketa, dan volume interaksi rendah (1 escrow = sedikit tx). Risiko eksekusi tinggi. Cocok bila targetnya Grand Prize dengan taruhan besar — tidak direkomendasikan sebagai pilihan utama.

## KONSEP C (alternatif): AVSC + Agent ID mint

Tambah modul gating Agent ID ke AVSC (mint gratis/berdiskon untuk pemegang .ai). Build tercepat (kontrak AVSC v4 sudah live) dan memakai proyek yang sudah ada (diizinkan). TETAPI: v4 tidak punya setter — perlu kontrak wrapper baru; AVSC 0 mint + tanpa komunitas; dan ini persis kategori yang sudah ramai (UNITS/Coracle/Oathbots). Innovation lemah, Popularity lemah. Hanya jadi fallback bila waktu mepet.

## Timeline (target submit 5–6 Des, 3–4 hari sebelum tenggat)

| Tanggal | Milestone |
|---|---|
| 19–21 Nov | Kunci konsep; riset resolusi nama; desain kontrak |
| 22–26 Nov | Kontrak + Foundry tests + deploy testnet (opBNB/BSC testnet) |
| 27–30 Nov | Frontend + skill.md + docs + repo GitHub publik |
| 1–3 Des | Deploy mainnet + verifikasi BscScan + uji end-to-end (check-in & attest dari bjorka01) |
| 4–6 Des | Submit proyek ke Binance; mulai dorong interaksi (Square + X) |
| 7–9 Des | Buffer + dorong interaksi lanjutan; tenggat 9 Des 15:00 WIB |

## Biaya (estimasi)

- Deploy kontrak ramping + verifikasi: ~0,0005–0,002 BNB (gas rendah). Saldo saat ini 0,00316 BNB — cukup secara teori, tanpa margin. **Top-up ~0,01 BNB disarankan.**
- Frontend Netlify + GitHub: $0. BscScan verify: $0.
- Interaksi pengguna: gas-only, checkIn ~53k gas (~0,000053 BNB @ 1 gwei), attest ~108k (~0,000108), claimQuest ~51k (~0,000051) — kisaran ~0,00005–0,00018 BNB/aksi @ 1 gwei.

## Keputusan yang diminta

Pilih konsep: **A (Agent Quests — rekomendasi)** / B (Escrow) / C (AVSC mint). Setelah dipilih, saya mulai desain kontrak + riset resolusi nama.
