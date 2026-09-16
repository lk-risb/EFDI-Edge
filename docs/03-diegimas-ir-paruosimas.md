# 03 — Diegimas ir paruošimas

## Reikalavimai

### Tuščio serverio paruošimas

`./install.sh` atnaujina OS (`apt upgrade`) ir savaime įdiegia git, Python
3.10+ bei Docker Engine + Compose papildinį (iš oficialios Docker
saugyklos, ne distributyvo paketą `docker.io`), jei jų trūksta — visiškai
tuščias Debian serveris tinka be jokio išankstinio paruošimo. Debian yra
šio projekto pagrindinis taikinys; RHEL/Rocky/Alma (`dnf`) palaikomas kiek
įmanoma, taip pat kaip tėviniame EFDI projekte.

Jei norite viską padaryti rankiniu būdu (arba automatinis diegimas
nepavyksta jūsų distributyve), rankiniai žingsniai tokie:

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y git curl ca-certificates
sudo apt install -y python3 python3-venv python3-pip

# Docker Engine + Compose papildinys (oficiali saugykla, ne docker.io)
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker "$USER"   # po to atsijunkite ir vėl prisijunkite
```

Patikrinkite: `python3 --version` (3.10+), `docker --version`, `docker compose version`.

### Tinklas

Šis routeris turi pasiekti savo tėvinį zenoh-gateway per NetBird — vienintelį
šio projekto naudojamą tinklo VPN. `install.sh` pasiūlo jį įdiegti ir
prijungti, jei dar neprijungtas. Jei norite prisijungti rankiniu būdu iš
anksto:

```bash
curl -fsSL https://pkgs.netbird.io/install.sh | sh
sudo netbird up --setup-key=<raktas>
```

### Registracijos raktas (enrollment token)

Prieš paleisdami `install.sh`, iš centrinio zenoh-gateway/SCOUT valdytojo
gaukite:

- Šliuzo WebUI bazinį URL (pvz., `https://zenoh-gateway.example`).
- Vienkartinį registracijos raktą, sugeneruotą šliuzo pusėje būtent šiam
  routeriui.
- Vardų sritį (namespace), po kuria registruotis — trumpą šio routerio
  identifikatorių (pvz., `site-alpha-radar`).

## Diegyklės paleidimas

```bash
curl -fsSL https://raw.githubusercontent.com/lk-risb/EFDI-Edge/main/install.sh | bash
```

Pirmas paleidimas nuklonuoja repozitoriją į `~/efdi-edge` (perrašoma su
`INSTALL_DIR=/path ./install.sh`) ir iš naujo paleidžia jau atsisiųstą
`install.sh`. Kiekvienas kitas paleidimas — įskaitant pakartotinį po
klaidos — vyksta jau su tuo pačiu katalogu.

Eiga:

1. **OS atnaujinimas.** Jei reikia perkrauti (branduolio ar bibliotekos
   atnaujinimas), diegyklė sustoja ir paprašo perkrauti bei paleisti iš
   naujo — saugu, niekas neprarandama.
2. **Būtinos priemonės.** Python, Docker, Compose, openssl. Jei Docker
   ką tik buvo įdiegtas, diegyklė sustoja ir paprašo naujos prisijungimo
   sesijos (grupės narystė `docker` grupei negalioja dabartinei sesijai)
   — po pakartotinio prisijungimo paleiskite `./install.sh` iš naujo.
3. **Tinklas.** Prisijunkite prie NetBird arba praleiskite šį žingsnį,
   jei tai vien lokalus bandomasis diegimas (be prisijungimo šis
   routeris nepasieks tikro tėvinio šliuzo).
4. **Routerio būsenos katalogas.** Kur laikoma Zenoh konfigūracija, TLS
   medžiaga ir žurnalai (`POD_STATE_DIR`, pagal nutylėjimą
   `~/efdi-edge-state`).
5. **Registracija.** Paprašo tėvinio šliuzo WebUI URL, šio routerio
   vardų srities, Zenoh fabriko galinio taško, į kurį jungtis (pvz.,
   `tls/zenoh-gateway.example:7447` — tikrasis mesh'o Zenoh prievadas,
   skirtingas nuo aukščiau nurodyto WebUI URL), ir registracijos rakto.
   Paleidžia `scripts/pki/enroll-router.sh`, kuris **lokaliai**
   sugeneruoja šio routerio CA, transporto ir politikos pasirašymo
   raktus, o tėviniam šliuzui siunčia tik CSR — joks privatus raktas
   niekada nepalieka šio įrenginio.
6. **Zenoh routerio konfigūracijos generavimas.** Nukopijuoja
   registruotą tapatybę į `${POD_STATE_DIR}/zenoh/tls/` (kelią, kurį
   iš tikrųjų prijungia konteineris) ir sugeneruoja
   `${POD_STATE_DIR}/zenoh/config.json5` pagal
   `examples/zenoh-router.json5.tmpl` — pilnas mTLS, `connect.endpoints`
   nustatytas pagal jūsų įvestį, ir tas pats federacijos ACL modelis kaip
   tėviniame EFDI projekte. `INBOUND_NAMESPACE` (dvišalis priešdėlis, į
   kurį fabrikui leidžiama siųsti duomenis) nuskaitomas iš tėvinio
   šliuzo pasirašyto delegavimo leidimo
   (`${POD_STATE_DIR}/pki/delegation.json`, kurį įrašo
   `scripts/pki/enroll-router.sh`) — jo `subscribe` sritis yra tiksliai
   ta rakto-išraiškos sritis, kurią šliuzas suteikė registracijos metu,
   todėl vardų sritis yra sertifikato, o ne spėjimo, rezultatas. Jei
   leidime nėra vienareikšmės `subscribe` srities, `install.sh` grįžta
   prie šio routerio nuosavos duomenų šaknies ir įspėja — tokiu atveju
   pasitikslinkite su tėvinio fabriko federacijos administratoriumi, ar
   šis routeris apskritai turėtų gauti įeinančius dvišalius duomenis.
7. **Vietinis valdymo agentas.** Sugeneruoja `EFDI_CONTROL_TOKEN` — raktą,
   kurį tėvinio šliuzo WebUI naudos nuotoliniam šio routerio valdymui
   (paleidimas/stabdymas/perkrovimas, konfigūracijos redagavimas,
   žurnalai). Šį raktą perduokite šliuzo administratoriui.
8. **`compose/.env` įrašymas, routerio ir valdymo plokštumos paleidimas.**

Kiekvieną žingsnį saugu kartoti: `.env` iki galo perrašomas tik pačioje
pabaigoje, sėkmingai atsakius į visus klausimus, o pakartotinio paleidimo
metu esamos reikšmės naudojamos kaip numatytosios.

## Po diegimo

```
./start.sh              # interaktyvus paslaugų paleidiklis
./start.sh --restore    # neinteraktyvus; atkuria paskutinį pasirinkimą
```

Šis routeris neturi vietinio WebUI. Norėdami patvirtinti, kad jis
pasiekiamas ir valdomas, paprašykite tėvinio zenoh-gateway administratoriaus
patikrinti, ar routeris matomas jų fabriko inspektoriuje (panoscope) ir ar
perkrovimo komanda jį pasiekia.

## Trikčių šalinimas

Žr. [04-dazniausios-problemos.md](04-dazniausios-problemos.md) — registracijos
klaidos, `admin-control` pasiekiamumas ir kitos diegimo/eksploatacijos
problemos.
