# Riset Resolusi Nama .ai On-Chain — HASIL: TERVERIFIKASI ✅

**Tanggal riset:** 19 Nov 2026
**Registry:** `0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F` (SPACE ID Agent ID, symbol `AI`, BSC mainnet, bytecode 8.756 byte)
**Metode:** disassembly bytecode (`cast disassemble`) → 58 konstanta PUSH4 → 33 fungsi di dispatcher → semua selector diresolusi via 4byte.directory → setiap klaim diuji dengan `eth_call` langsung ke BSC mainnet (RPC bsc-dataseed).

## Kesimpulan

**Resolusi nama .ai dua arah TERSEDIA on-chain di registry itu sendiri.** Desain boleh memakainya untuk tampilan/resolusi di frontend; kontrak inti tetap memakai `balanceOf` sebagai gate (paling murah gas-nya) dan TIDAK perlu memanggil fungsi string on-chain di jalur state-changing.

## Fungsi resolusi (semua terverifikasi live)

| Fungsi | Selector | Perilaku terverifikasi |
|---|---|---|
| `ownerOfHandle(string handle)` | `0x1da94fb4` | Nama → alamat pemilik. `ownerOfHandle("bjorka01")` → `0xE5B708CB1C90e04B4922A078389E4C0B880B4DbA` ✅. Nama **TANPA** suffix `.ai`: `ownerOfHandle("bjorka01.ai")` → `0x0000…0000`. Nama tak terdaftar → `0x0000…0000`. |
| `handleOf(address)` | `0xc50a1514` | Alamat → nama. `handleOf(0xE5B708CB…B4DbA)` → `"bjorka01"` ✅ (tanpa `.ai`). Alamat tanpa handle → string kosong `""`. |
| `isValidHandle(string)` | `0x3ff4dbc2` | `isValidHandle("bjorka01")` → `true`; `isValidHandle("BJORKA01")` → `false` (huruf kecil saja). |
| `register(string,uint256,bytes)` | `0x8580974c` | Registrasi dengan tanda tangan EIP-712 (deadline + signature). Tidak diuji tx-nya (butuh signature sah dari signer). |
| `adminRegister(string,address)` | `0xc5c94763` | Registrasi oleh owner. |

## Model token (terverifikasi)

- **Token ID = `uint256(keccak256(handle))`** — BUKAN nomor urut. `ownerOf(keccak256("bjorka01"))` → wallet ✅. Inilah sebabnya probe lama `tokenURI(1)` / `tokenOfOwnerByIndex` gagal: token 1 tidak ada.
- `tokenURI(tokenId)` → `https://agentid.prd.space.id/metadata/<handle>.json` (baseURI `https://agentid.prd.space.id/metadata/`, suffix `.json`).
- **Soulbound:** transfer revert dengan error `Soulbound()` (`0xa4420a95`).
- `supportsInterface`: ERC-721 ✅, ERC-721Metadata ✅, ERC-721Enumerable ❌ (tidak ada `totalSupply` / enumerasi).
- Panjang handle: `minLen() = 3`, `maxLen() = 20`, `LEN_CEILING() = 64`.
- `signer()` = `owner()` = `0x457c1fd14750c6c30886a2f2b57f1ef44b095882`.
- `eip712Domain()` tersedia (registrasi memakai EIP-712).

## Interface lengkap registry (33 fungsi eksternal, semua teridentifikasi)

ERC-721: `name()`, `symbol()`, `balanceOf(address)`, `ownerOf(uint256)`, `tokenURI(uint256)`, `approve(address,uint256)`, `getApproved(uint256)`, `setApprovalForAll(address,bool)`, `isApprovedForAll(address,address)`, `transferFrom(address,address,uint256)`, `safeTransferFrom(address,address,uint256)`, `safeTransferFrom(address,address,uint256,bytes)`, `supportsInterface(bytes4)`.
Handle: `handleOf(address)`, `ownerOfHandle(string)`, `isValidHandle(string)`, `register(string,uint256,bytes)`, `adminRegister(string,address)`.
Config: `baseURI()`, `uriSuffix()`, `setURIParts(string,string)`, `minLen()`, `maxLen()`, `LEN_CEILING()`, `setLengthBounds(uint8,uint8)`, `signer()`, `setSigner(address)`, `eip712Domain()`.
Ownership (Ownable2Step): `owner()`, `pendingOwner()`, `transferOwnership(address)`, `acceptOwnership()`, `renounceOwnership()`.

Konstanta PUSH4 lain yang tidak teresolusi (`0x0a85bd01`, `0x22718ad9`, `0x2bfd17e9`, `0x2cd44ac3`, `0x32505749`, `0x35e2f383`, `0x39e35637`, `0xff774c29`) TIDAK ada di dispatcher — semuanya konstanta internal (selector error / interface ID / auxdata), bukan fungsi eksternal.

## Bukti mentah (eth_call, 19 Nov 2026)

```
handleOf(0xE5B708CB1C90e04B4922A078389E4C0B880B4DbA)
→ 0x…00000008 626a6f726b613031… = "bjorka01"

ownerOfHandle("bjorka01")
→ 0x000000000000000000000000e5b708cb1c90e04b4922a078389e4c0b880b4dba

ownerOfHandle("bjorka01.ai") → 0x0000000000000000000000000000000000000000000000000000000000000000
handleOf(0x0000000000000000000000000000000000000001) → "" (length 0)
ownerOfHandle("zzzznonexistenthandle") → 0x0000000000000000000000000000000000000000000000000000000000000000
ownerOf(0xc39631e3776f4d3310f4069ab9c1cc1b37878e4a73cd8bebe13f07aff350daa4) → 0xE5B708CB…B4DbA
  (tokenId = keccak256("bjorka01"))
tokenURI(keccak256("bjorka01")) → "https://agentid.prd.space.id/metadata/bjorka01.json"
```

File pendukung: `research/registry.bytecode`, `research/registry.disasm`, `research/selectors.txt`, `research/selectors-resolved.txt`.

## Implikasi desain untuk AgentQuests

1. **Gate tetap `balanceOf > 0`** — paling murah dan sudah terbukti dipakai UNITS/Coracle/Oathbots.
2. **Frontend** bisa menampilkan nama .ai: panggil `handleOf(address)` (eth_call gratis) untuk leaderboard/profil; panggil `ownerOfHandle(handle)` untuk mengubah input nama → alamat sebelum `attest(address)`. Ingat: handle tanpa suffix `.ai`.
3. **Kontrak TIDAK memanggil fungsi string** (`handleOf`/`ownerOfHandle`) di jalur state-changing — hemat gas dan hemat bytecode. `attest()` menerima `address` (frontend yang me-resolve).
4. **Opsi fase 2 (tidak di fase 1):** `attestByHandle(string)` yang memanggil `ownerOfHandle` on-chain — menambah gas + kompleksitas; hanya bila UX membutuhkannya.
5. **Catatan keamanan:** `ownerOfHandle` mengembalikan `0x0` untuk nama tak terdaftar — frontend WAJIB menolak attest ke alamat `0x0` (kontrak juga menolak: target tanpa Agent ID revert).
