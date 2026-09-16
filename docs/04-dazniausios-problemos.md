# 04 — Dažniausios problemos

Simptomais pagrįsti sprendimai problemoms, kylančioms diegiant ar
eksploatuojant EFDI-Edge routerį — įskaitant paprastą sumaištį dėl to,
kuri reikšmė kur turi eiti, ne vien avarijas. Perskaitykite prieš iš
naujo tirdami kažką, kas atrodo pažįstama; jei aptikote ką nors naujo,
pridėkite tai čia, kad kitam nereikėtų iš naujo pereiti to paties kelio.

### Zenoh ryšio klaida

**Simptomas:** `zenoh.ZError: Unable to connect to any of [tls/zenoh...]`

```bash
# 1. Patikrinkite, ar routeris sveikas
docker compose -f compose/docker-compose.yml ps zenoh-router

# 2. Patikrinkite, ar nustatytas galinio taško kintamasis
echo $ZENOH_LOCAL_ENDPOINT   # tikimasi: tcp/127.0.0.1:7448

# 3. Patikrinkite, ar egzistuoja sertifikatų failai
ls $EFDI_CERT_DIR/*.pem
```

Jei `compose/.env` buvo įkeltas paprastu `source compose/.env`, kintamieji
neeksportuojami vaikiniams procesams. Naudokite `./start.sh` (kuris tai
sutvarko), arba:

```bash
set -a && source compose/.env && set +a
```

### TLS/mTLS tapatybės profilis turi atitikti galinį tašką, į kurį jungiamasi

**Simptomas:** Bandymas prisijungti prie tėvinio šliuzo nesukelia jokios
klaidos ir jokio ryšio — atrodo lygiai taip pat kaip DNS ar užkardos
problema.

**Priežastis:** tėvinis šliuzas ir bet kuris kitas fabrikas, prie kurio
šis routeris kada nors jungtųsi, kiekvienas pasirašytas **skirtingo CA**.
Nukreipus teisingą galinį tašką į neteisingą sertifikato tapatybę, mTLS
prisijungimas nutrūksta tyliai, be aiškaus atmetimo.

**Sprendimas:** registracijos metu įvestas Zenoh fabriko galinis taškas ir
šio routerio paties registruota tapatybė (iš
`scripts/pki/enroll-router.sh`) yra viena nedaloma pora — niekada
nemaišykite vienos registracijos galinio taško su kitos registracijos
sertifikatais.

### NetBird split-DNS nematomas konteineriuose

**Simptomas:** `compose/.env` nurodo Zenoh galinį tašką per mesh vardą
(pvz., `zenoh-gateway.example`); `zenoh-router` konteineris net
nebando jungtis — nei lizdo, nei TLS klaidos, tiesiog tyla.

**Priežastis:** `network_mode: host` bendrina tinklo *vardų sritį*, bet ne
`/etc/resolv.conf`. NetBird split-DNS skiriamoji geba mesh domenui veikia
tik **pagrindiniame** įrenginyje; konteineris gauna savo paties Docker
sugeneruotą DNS serverį, kuris apie mesh domeną nieko nežino. Vardas
sėkmingai išsprendžiamas pagrindiniame įrenginyje (`getent hosts` ten
veikia), bet tyliai nepavyksta konteineryje.

**Sprendimas:** pridėkite aiškų `extra_hosts` įrašą, susiejantį mesh vardą
su dabartiniu NetBird IP adresu `zenoh-router` compose paslaugos
apibrėžime. Atnaujinkite jį, jei NetBird kada nors priskiria kitą IP.

### Vienodo pavadinimo pasikartojantys funkcijų apibrėžimai tyliai užstoja vienas kitą

**Simptomas:** Kodas, kurį skaitote `compose/control/` ar
`compose/protocols/`, atrodo akivaizdžiai neteisingas (klaidinga logika,
klaida, kuri turėtų būti labai pastebima) — bet veikiančios sistemos
elgsena atrodo tvarkinga.

**Priežastis:** Python leidžia iš naujo apibrėžti funkciją modulio lygyje
be jokio įspėjimo. Jei faile tas pats funkcijos pavadinimas apibrėžtas du
kartus, **antrasis** apibrėžimas tyliai laimi — pirmasis tampa negyvu
kodu, kuris vis dar atrodo veikiantis.

**Sprendimas:** prieš pasitikėdami, kad skaitoma funkcija yra ta pati,
kuri iš tikrųjų vykdoma, patikrinkite vykdymo metu:
`python3 -c "import inspect; from module import the_func; print(inspect.getsourcelines(the_func))"`
parodys, kurio apibrėžimo eilutės numeris iš tikrųjų naudojamas.

### `pip install` nepavyksta su „externally-managed-environment"

**Simptomas:** Paleidus `pip install -r requirements.txt` tiesiai su
sistemos `python3` (o ne per `install.sh`/`start.sh`), gaunama klaida
`error: externally-managed-environment` (PEP 668, dažna moderniose
Debian/Ubuntu sistemose).

**Priežastis:** sistemos Python sąmoningai apsaugotas nuo nevaldomo `pip
install`. `install.sh`/`start.sh` su tuo nekovoja — jie sukuria ir naudoja
savo virtualią aplinką `compose/venv`.

**Sprendimas:** naudokite tą aplinką tiesiogiai:

```bash
compose/venv/bin/pip install -r compose/requirements.txt
compose/venv/bin/python3 control/some_script.py
```

Niekada neperduokite `--break-system-packages` sistemos `pip`.

### Dubliuoti proceso egzemplioriai

**Simptomas:** Veikia dvi tos pačios paslaugos kopijos — dažniausiai dėl
`./start.sh` paleidimo du kartus, prieš tai nesustabdžius.

**Sprendimas:**

```bash
./stop.sh
rm -f compose/state/.pids/*.pid
./start.sh
```

### Kodo pataisymas neįsigalioja, kol veikiantis procesas neperkraunamas

**Simptomas:** Ištaisote klaidą `admin_control.py`, `supervisor.py` ar
bet kur po `compose/protocols/`, patvirtinate, kad failas diske pasikeitė,
o veikiančios sistemos elgsena nepasikeičia.

**Priežastis:** `.py` failo redagavimas neturi jokios įtakos jau
veikiančiam interpretatoriui, kuris atmintyje laiko seną baitkodą.

**Sprendimas:** prieš darydami išvadą, kad pataisymas neveikia,
perkraukite konkretų procesą, kuris importuoja pakeistą failą (ne tik tą,
kuris strigo, jei tai bendras modulis, pvz.,
`compose/protocols/gateway.py`).

### `TypeError` nurodo parametrą, kurio dabartiniame kode nėra

**Simptomas:** Ilgai veikiantis procesas meta `TypeError`, nurodydamas
kažkokį parametrą — bet ieškant to parametro pavadinimo visoje
repozitorijoje (`grep`) nieko nerandama; funkcijos tikroji, diske esanti
signatūra niekada neturėjo tokio pavadinimo parametro.

**Priežastis:** pasenusi `__pycache__/*.pyc`, sukompiliuota iš ankstesnės
bendro modulio versijos (pvz., `compose/protocols/gateway.py`), užstoja
dabartinį kodą.

**Sprendimas:**

```bash
find compose -name '__pycache__' -exec rm -rf {} +
# tada perkraukite kiekvieną procesą, kuris importuoja paveiktą modulį
```

### Registracija nepavyksta su HTTP klaida

**Simptomas:** `scripts/pki/enroll-router.sh` (paleidžiamas per
`install.sh`) baigiasi HTTP klaida, jungiantis prie tėvinio zenoh-gateway.

**Priežastis:** beveik visada tai neteisingas URL arba jau panaudotas/
pasibaigęs raktas. Registracijos URL yra tėvinio šliuzo **zenoh-admin
WebUI bazinis adresas** (pvz., `https://gateway.example`) — lengva vietoj
jo įvesti `admin-control` prievadą (`18896`), kuris yra *kita* paslauga
tame pačiame įrenginyje, naudojama nuolatiniam nuotoliniam valdymui po
registracijos, o ne pačiai registracijai. Registracijos raktas taip pat
galioja tik vieną kartą ir ribotą laiką; pakartotinis jau panaudoto rakto
naudojimas arba per ilgas laukimas po jo išdavimo baigiasi ta pačia
klaida.

**Sprendimas:** patikrinkite, ar URL yra WebUI bazinis adresas, o ne
`:18896`, ir, jei senas raktas galėjo būti jau panaudotas ar pasibaigęs,
gaukite naują iš tėvinio šliuzo.

### `admin-control` nepasiekiamas iš tėvinio šliuzo

**Simptomas:** Registracija pavyksta ir routeris pasileidžia, bet tėvinio
šliuzo fabriko inspektorius (panoscope) niekada neparodo jo kaip valdomo,
arba perkrovimo komanda iš tėvinio šliuzo niekada jo nepasiekia.

**Priežastis:** `EFDI_CONTROL_BIND` faile `compose/.env` vis dar yra
`127.0.0.1` (tik lokalus prievadas) — tinkama routeriui, kuris valdo tik
save patį, bet tėvinis šliuzas yra *kitas* įrenginys ir negali pasiekti
paslaugos, prijungtos tik prie loopback sąsajos, per tinklą.

**Sprendimas:** nustatykite `EFDI_CONTROL_BIND` į mesh VPN sąsajos
(paprastai NetBird) adresą, arba `0.0.0.0`, jei šiam diegimui priimtina
klausyti visų sąsajų, tada perkraukite `admin-control`.

### Zenoh routeris nepasileidžia sveikas

**Simptomas:** `docker compose -f compose/docker-compose.yml ps` rodo
`zenoh-router` kaip nesveiką arba nuolat besiperkraunantį.

**Priežastis:** dažniausiai trūksta arba yra sugadintas
`compose/state/zenoh/config.json5` — šis failas sugeneruojamas registracijos
žingsnio metu, o ne rašomas rankiniu būdu; jei registracija nepavyko per
pusę (žr. HTTP klaidos įrašą aukščiau) arba buvo pertraukta, jis gali
trūkti arba būti tik iš dalies parašytas.

**Sprendimas:**

```bash
docker compose -f compose/docker-compose.yml logs zenoh-router
```

Jei žurnale minimas trūkstamas/neteisingas `config.json5`, paleiskite
`scripts/pki/enroll-router.sh` iš naujo (saugu kartoti — žr.
[03-diegimas-ir-paruosimas.md](03-diegimas-ir-paruosimas.md)), o ne
redaguokite sugeneruotą failą rankiniu būdu.

### „Čia nėra jokio skydelio, ar jis apskritai kažką daro?"

**Simptomas:** Po švaraus diegimo lokaliai nėra į ką pažiūrėti — nėra
WebUI, jokio akivaizdaus patvirtinimo, kad routeris atlieka savo darbą.

**Priežastis:** taip sukurta sąmoningai, tai nėra trūkstama funkcija.
EFDI-Edge yra be galvos (headless) routeris su nuotoline valdymo
plokštuma; jis sąmoningai neturi vietinio skydelio (žr. tėvinio README
skyrių „Relationship to the parent EFDI repo").

**Sprendimas:** patvirtinkite veikimą iš *tėvinio* šliuzo pusės, o ne
ieškokite vietinės sąsajos — paprašykite šliuzo administratoriaus
patikrinti, ar routeris matomas jų fabriko inspektoriuje (panoscope) ir
ar iš ten išsiųsta perkrovimo komanda iš tikrųjų jį pasiekia. Lokaliai
vienintelis „skydelis" yra `tail -f
compose/state/logs/<paslauga>.log`.
