#set document(title: "IoT w siatce usług — dokumentacja projektu", author: "Oleksandr Nychyporchuk")
#set page(paper: "a4", margin: (x: 2.5cm, y: 2.5cm), numbering: "1")
#set text(font: "New Computer Modern", size: 11pt, lang: "pl")
#set par(justify: true)
#set heading(numbering: "1.")
#show link: underline
#show heading.where(level: 1): it => { v(0.3cm); it; v(0.15cm) }

// pomocnicze
#let note(body) = block(fill: luma(240), inset: 9pt, radius: 3pt, width: 100%, body)
#let head-fill = (_, row) => if row == 0 { luma(220) } else { white }

// rysunek oparty na pliku w documentation/images/
#let figpic(path, cap) = figure(image(path, width: 100%), caption: cap)

// symbol zastępczy dla zrzutów jeszcze nie wykonanych
#let figplace(path, cap, h: 5.5cm) = figure(
  rect(width: 100%, height: h, stroke: (paint: gray, dash: "dashed"), fill: luma(247))[
    #align(center + horizon)[
      #text(fill: gray, size: 10pt)[Miejsce na zrzut ekranu \ dodaj #raw(path)]
    ]
  ],
  caption: cap,
)

#align(center)[
  #v(2cm)
  #text(size: 24pt, weight: "bold")[IoT w Service Mesh]
  #v(0.3cm)
  #text(size: 13pt, fill: gray)[Platforma czujników LoRaWAN działająca na MicroK8s,
  zabezpieczona od końca do końca przez Linkerd i dostarczana w modelu GitOps]
  #v(16cm)
  #text(size: 11pt)[Oleksandr Nychyporchuk 196659, Maksym Nievierov 211996, Mikołaj Klikowicz 193264, Bartosz Sontowski 193551, Mateusz Chmielewski 193661]
  
  #v(0.1cm)
]

#v(1cm)
#line(length: 100%)
#v(0.3cm)
#pagebreak()
#outline(title: "Spis treści", depth: 2, indent: auto)
#pagebreak()

= Wprowadzenie

Ten projekt to potok danych LoRaWAN działający na klastrze Kubernetes. Fizyczne czujniki
Milesight wysyłają odczyty drogą radiową do bramy, która przekazuje je do klastra, gdzie
ramki są dekodowane, zapisywane w PostgreSQL i prezentowane na panelu webowym.

Wszystko w klastrze działa wewnątrz siatki usług o architekturze zero zaufania zbudowanej z
*Linkerd*: pody komunikują się tylko tam, gdzie pozwala na to jawna polityka, a ten ruch jest
automatycznie wzajemnie uwierzytelniany i szyfrowany przez mTLS. Platforma jest deklaratywna
od końca do końca, opisana w repozytorium Git i uzgadniana przez *ArgoCD*.

Dokument ten obejmuje architekturę, sprzęt, maszyny wirtualne, stos technologiczny, decyzje
projektowe stojące za naszymi manifestami, automatyzację oraz zestaw dowodów na to, że model
bezpieczeństwa działa.

= Architektura

== Przepływ danych od końca do końca

Pojedynczy odczyt przechodzi przez system w następujący sposób:

```
 czujniki Milesight (WS101 / WS202 / WS302)
        |  radio LoRa (EU868)
        v
 brama Milesight UG63
        |  Semtech UDP (packet-forwarder)  ->  NodePort 31700/UDP
        v
 chirpstack-gateway-bridge --MQTT--> mosquitto --MQTT--> chirpstack
        ^                                                    |
        |                       odszyfrowuje + deduplikuje    |
        |                       ramkę, uruchamia kodek JS      v
        |                            zdekodowany uplink publikowany na MQTT
        |                                                    |
        |                                                    v
        +------------------------------------------> Node-RED  (subskrybuje)
                                                            | INSERT
                                                            v
                                                     PostgreSQL (device_uplinks)
                                                            ^
                                                            | SELECT
                                          iot-stat-reader (FastAPI)
                                                            ^
                                                            | /api (odwrotne proxy nginx)
                                          iot-stat-frontend (panel React)
```

Każda strzałka na tym schemacie, która przekracza granicę poda wewnątrz klastra, jest
opakowywana we wzajemny TLS przez kontener pomocniczy (sidecar) Linkerd i jest dozwolona
tylko dlatego, że pewna polityka autoryzacji wskazuje konkretną tożsamość klienta. Kod
aplikacji nie jest świadomy, że to się dzieje.

== Widok logiczny

Platforma dzieli się na cztery warstwy. *Warstwa platformy* to sam klaster MicroK8s.
*Warstwa siatki* to Linkerd wraz z rozszerzeniem obserwowalności Viz. *Warstwa dostarczania*
to ArgoCD. *Warstwa aplikacji* to stos LoRaWAN (ChirpStack, jego gateway bridge, Mosquitto,
PostgreSQL, Redis) razem z naszym własnym kodem spajającym i usługami prezentacji (Node-RED,
iot-stat-reader, iot-stat-frontend). Wszystkie obciążenia aplikacyjne żyją w jednej
przestrzeni nazw, `iot-system`; ArgoCD działa w `argocd`, a Linkerd w `linkerd` /
`linkerd-viz`.

#figure(image("images/architecture-pl.png", height: 13cm),
  caption: [Przegląd komponentów i ruchu. Czujniki i brama zasilają stos LoRaWAN;
  każde połączenie w przestrzeni `iot-system` jest zabezpieczone przez mTLS Linkerd.])

= Sprzęt

== Urządzenia IoT

Używamy trzech czujników Milesight LoRaWAN; wszystkie dołączają do sieci metodą OTAA i
wszystkie pracują w paśmie EU868. Są celowo różne, aby panel miał do pokazania zarówno dane
liczbowe, jak i kategoryczne. Każdy czujnik ma własny kodek ładunku w JavaScript,
zarejestrowany w ChirpStack poprzez profil urządzenia, który zamienia surowy binarny uplink
na nazwane pola.

#table(
  columns: (auto, auto, 1fr, auto),
  stroke: 0.5pt,
  fill: head-fill,
  [*Urządzenie*], [*Model*], [*Co raportuje*], [*Uplink*],
  [Button-1], [Milesight WS101], [Zdarzenia naciśnięcia przycisku (pojedyncze / podwójne / długie), bateria i status urządzenia], [przy naciśnięciu],
  [PIR&Light Sensor], [Milesight WS202], [Ruch (PIR) i stan oświetlenia dziennego, bateria], [~5 min],
  [Sound Level Sensor], [Milesight WS302], [Poziom dźwięku (LAeq), bateria i status urządzenia], [~1 min],
)

#table(
  columns: (auto, auto, auto, auto),
  stroke: 0.5pt,
  fill: head-fill,
  [*Nazwa*], [*DevEUI*], [*Profil*], [*Kodek*],
  [Button-1], [`24e124535c271986`], [WS101 Button], [`ws101-decoder.js`],
  [PIR&Light Sensor], [`24e124538c421853`], [WS202 PIR Light], [`ws202-decoder.js`],
  [Sound Level Sensor], [`24e124743d186530`], [WS302 Sound Level], [`ws302-decoder.js`],
)

Klucze aplikacyjne OTAA poszczególnych urządzeń (`APPKEY_<DEVEUI>`) nie są przechowywane w
repozytorium. Żyją w pliku `.env` wykluczonym z Gita i są przekazywane skryptowi
provisioningu w czasie działania.

#figpic("images/chirpstack_device_profiles.png",
  [Trzy profile urządzeń w konsoli ChirpStack, każdy powiązany ze swoim kodekiem ładunku
  w JavaScript.])

== Brama LoRaWAN

Strona radiowa kończy się na bramie *Milesight UG63* (UG63-868M), zarejestrowanej w
ChirpStack pod identyfikatorem `24e124fffef8026e`. Brama uruchamia standardowy Semtech UDP
packet-forwarder i kieruje go do klastra. W jej konfiguracji ustawiliśmy interwał statystyk
na 30 sekund; ChirpStack używa tego interwału do decyzji, czy brama jest online — jeśli
pozostawić wartość domyślną, brama pokazuje się jako offline, mimo że ramki wciąż
przychodzą.

Brama łączy się z klastrem przez pojedynczy NodePort UDP (31700), który jest jedynym punktem
wejścia dla ruchu radiowego.

= Infrastruktura

== Maszyny wirtualne

Klaster działa na czterech maszynach wirtualnych w sieci `10.29.16.0/24`. Trzy z nich tworzą
klaster MicroK8s; czwarta to osobny generator obciążenia, który celowo trzymamy poza
klastrem.

#table(
  columns: (auto, auto, 1fr),
  stroke: 0.5pt,
  fill: head-fill,
  [*Host*], [*Adres*], [*Rola*],
  [`cp`], [`10.29.16.101`], [Warstwa sterowania; również planuje obciążenia],
  [`worker1`], [`10.29.16.102`], [Węzeł roboczy],
  [`worker2`], [`10.29.16.103`], [Węzeł roboczy],
  [`load-gen`], [`10.29.16.104`], [Generator obciążenia k6, poza klastrem],
)

== Klaster Kubernetes

Wybraliśmy *MicroK8s* (Kubernetes pakowany w snap od Canonical), ponieważ jest na tyle
lekki, że wygodnie działa na tych maszynach, i dlatego, że dołączenie kolejnych węzłów to
jedno polecenie. Warstwa sterowania także uruchamia obciążenia, więc wszystkie trzy węzły
klastra przyjmują pody.

Na bazowej instalacji włączamy trzy dodatki: `dns` (CoreDNS), `hostpath-storage` (który
stoi za roszczeniami PersistentVolumeClaim dla PostgreSQL i Node-RED) oraz repozytorium
`community`. Instalujemy też na poziomie klastra CRD-y *Gateway API*, ponieważ stos polityk
Linkerd zależy od ich obecności.

= Stos technologiczny

#table(
  columns: (auto, 1fr, auto),
  stroke: 0.5pt,
  fill: head-fill,
  [*Komponent*], [*Rola w projekcie*], [*Warstwa*],
  [MicroK8s], [Lekki klaster Kubernetes (1 warstwa sterowania + 2 robocze)], [Platforma],
  [Linkerd], [Siatka usług: mTLS, tożsamość obciążeń, autoryzacja zero zaufania], [Siatka],
  [Linkerd Viz], [Obserwowalność: Prometheus, Tap, panel], [Siatka],
  [ArgoCD], [Dostarczanie GitOps; uzgadnia każdą aplikację z Gita], [Dostarczanie],
  [ChirpStack v4], [Serwer sieciowy i aplikacyjny LoRaWAN], [Aplikacja],
  [ChirpStack Gateway Bridge], [Semtech UDP packet-forwarder na MQTT], [Aplikacja],
  [Eclipse Mosquitto], [Broker MQTT między gateway-bridge a ChirpStack], [Aplikacja],
  [PostgreSQL / Redis], [trwałe dane ChirpStack i aplikacji / pamięć podręczna oraz strumienie runtime], [Dane],
  [Node-RED], [Silnik przepływów: MQTT do PostgreSQL], [Aplikacja],
  [iot-stat-reader], [Usługa FastAPI udostępniająca zapisane uplinki], [Aplikacja],
  [iot-stat-frontend], [Panel React + Tailwind (budowa Vite, serwowanie nginx)], [Aplikacja],
  [Ansible + Make], [Provisioning, wdrożenie, usuwanie, rejestracja urządzeń], [Automatyzacja],
)

= Decyzje projektowe

Ta sekcja odczytuje nasze decyzje z manifestów, zamiast opisywać narzędzia w oderwaniu.
Każda z nich to coś, co moglibyśmy zmienić w YAML-u i zobaczyć efekt.

== Jedna umieszczona w siatce przestrzeń z domyślną blokadą

Wszystko, co aplikacyjne, żyje w `iot-system`, a sama przestrzeń nazw niesie postawę
bezpieczeństwa w postaci adnotacji.

```yaml
metadata:
  name: iot-system
  annotations:
    linkerd.io/inject: enabled                       # umieść w siatce każdy pod tutaj
    config.linkerd.io/default-inbound-policy: deny   # domyślne zero zaufania
    config.linkerd.io/opaque-ports: "1883"           # MQTT to surowy TCP
```

Ustawienie tego raz na przestrzeni nazw oznacza, że nigdy nie powtarzamy tego per
obciążenie. `inject: enabled` sprawia, że Linkerd automatycznie dodaje swój sidecar do
każdego nowego poda, dlatego każdy pod aplikacyjny działa jako `2/2`.
`default-inbound-policy: deny` jest tu kluczowe: przy tym ustawieniu każde przychodzące
połączenie do dowolnego poda jest odrzucane, jeśli `AuthorizationPolicy` go wprost nie
dopuści. Nic nie jest osiągalne przez przypadek.

== Autoryzacja jako jawne listy dozwolonych

Ponieważ domyślną zasadą jest blokada, dostęp trzeba przyznawać świadomie. Robimy to za
pomocą czterech rodzajów zasobów Linkerd współpracujących ze sobą. `Server` oznacza port na
zbiorze podów jako chroniony cel. `AuthorizationPolicy` wiąże ten `Server` z jednym lub
wieloma uwierzytelnieniami. `MeshTLSAuthentication` identyfikuje rozmówców po ich tożsamości
w siatce (po koncie ServiceAccount Kubernetes), a `NetworkAuthentication` identyfikuje ich po
sieci źródłowej. Łącznie manifesty definiują *9 zasobów `Server`, 13 `AuthorizationPolicy`, 5
`MeshTLSAuthentication` i 4 `NetworkAuthentication`*. Wynikowa macierz dostępu wygląda tak:

#table(
  columns: (auto, auto, 1fr),
  stroke: 0.5pt,
  fill: head-fill,
  [*Server (port)*], [*Protokół*], [*Kto może się połączyć i jak*],
  [`postgres-server` (5432)], [opaque], [tożsamości mTLS: `chirpstack`, `iot-stat-reader`, `nodered`],
  [`redis-server` (6379)], [opaque], [tożsamość mTLS: `chirpstack`],
  [`mosquitto-mqtt` (1883)], [opaque], [tożsamości mTLS: `mqtt-client`, `chirpstack`, `gateway-bridge`, `node-red`],
  [`chirpstack-api` (8080)], [opaque], [mTLS `chirpstack` (wewnętrznie) i sieć `0.0.0.0/0` (UI/gRPC)],
  [`iot-stat-reader-http` (8000)], [HTTP/1], [sieć `0.0.0.0/0` (zewnętrzne API)],
  [`iot-stat-frontend-http` (80)], [HTTP/1], [sieć `0.0.0.0/0` (zewnętrzne UI)],
  [`nodered-ui` (1880)], [HTTP/1], [sieć `0.0.0.0/0` (zewnętrzny edytor)],
  [`proxy-admin` (4191)], [HTTP/1], [tożsamości mTLS: `prometheus`, `tap`],
  [`proxy-tap` (4190)], [HTTP/2], [tożsamość mTLS: `tap`],
)

#note[
  *Obrona w głąb.* Usługa może być osiągalna spoza klastra tylko wtedy, gdy ma zarówno
  NodePort (ścieżkę sieciową), jak i politykę autoryzacji dopuszczającą sieć źródłową.
  Magazyny danych (PostgreSQL, Redis, Mosquitto) nie mają ani NodePort, ani reguły
  `0.0.0.0/0`. Są ograniczone do konkretnych tożsamości w siatce, więc nawet skompromitowany
  pod wewnątrz klastra nie może ich osiągnąć, o ile nie posiada autoryzowanej tożsamości.
]

== Porty „opaque” dla ruchu innego niż HTTP

Domyślnie Linkerd zakłada, że port mówi po HTTP, i próbuje go parsować na warstwie 7. Dla
protokołów binarnych jest to błędne, więc takie porty oznaczamy jako *opaque*. Wciąż są
szyfrowane przez mTLS i wciąż podlegają autoryzacji; Linkerd traktuje je tylko jak surowy
TCP.

#table(
  columns: (auto, 1fr),
  stroke: 0.5pt,
  fill: head-fill,
  [*Port*], [*Dlaczego oznaczyliśmy go jako opaque*],
  [`1883` (Mosquitto)], [MQTT to binarny protokół TCP. Ustawione dla całej przestrzeni przez `opaque-ports`.],
  [`5432` / `6379`], [Protokoły sieciowe PostgreSQL i Redis są binarne.],
  [`8080` (chirpstack-api)], [Serwuje zarówno grpc-web z przeglądarki (HTTP/1), jak i natywny gRPC (HTTP/2). Jedno ustawienie L7 nie obejmie obu, więc opaque przepuszcza oba. Natywny gRPC był nam potrzebny do skryptu bootstrap urządzeń.],
)

== Trzymanie poświadczeń poza Gitem

Żadne hasło ani klucz nie są commitowane. Dwa zasoby Secret Kubernetes (`chirpstack-secret`
i `postgres-credentials`) są tworzone przez playbook konfiguracyjny z pliku `.env`
wykluczonego z Gita, zanim ArgoCD wdroży obciążenia, które je montują. Gdybyśmy pozwolili
ArgoCD najpierw uruchomić ChirpStack, jego pod utknąłby w `CreateContainerConfigError` z
powodu brakującego sekretu, więc ta kolejność jest celowa. Klucze OTAA urządzeń również żyją
wyłącznie w `.env`.

== Samonastawne, odtwarzalne obciążenia

Kilka obciążeń wykonuje drobne kroki konfiguracji samodzielnie, aby świeży klaster nie
wymagał ręcznych poprawek:

- *PostgreSQL* uruchamia przy pierwszym starcie ConfigMap `init.sql`, który tworzy naszą
  tabelę `device_uplinks` oraz wyzwalacz powiadomień `new_uplink`, obok własnego schematu
  ChirpStack.
- *Node-RED* ma inicjujący kontener seed, który kopiuje commitowany `flows.json` do świeżego
  wolumenu `/data` i instaluje węzeł palety PostgreSQL, z zabezpieczeniem, by nigdy nie
  nadpisać istniejących danych. Hasło do bazy trafia do przepływu jako zmienna środowiskowa z
  sekretu `postgres-credentials`, więc żadne poświadczenie nie jest zapisane w samym
  przepływie.
- *iot-stat-frontend* jest serwowany przez nginx, który dodatkowo działa jako odwrotne proxy
  `/api` do wewnętrznego `iot-stat-reader`. Przeglądarka rozmawia wyłącznie z origin
  frontendu, więc nie ma konfiguracji CORS ani zaszytego w buildzie adresu backendu. Upstream
  jest rozwiązywany leniwie przez DNS klastra, więc pod nie wpada w pętlę restartów, gdy
  backend jest przez chwilę nieobecny.

#figpic("images/nodered-gui.png",
  [Przepływ Node-RED: subskrypcja zdekodowanych uplinków z ChirpStack przez MQTT,
  przekształcenie każdej wiadomości i wstawienie jej do tabeli `device_uplinks`.])

== Powierzchnia wystawiona na zewnątrz

Tylko pięć rzeczy jest osiągalnych spoza klastra i są to dokładnie te, które zamierzamy
wystawić:

#table(
  columns: (auto, auto, 1fr),
  stroke: 0.5pt,
  fill: head-fill,
  [*Usługa*], [*NodePort*], [*Powód*],
  [chirpstack-gateway-bridge], [`31700/UDP`], [Odbiera ramki z bramy LoRa],
  [chirpstack-ui], [`30080`], [Konsola administracyjna ChirpStack + gRPC],
  [nodered-ui], [`31880`], [Edytor Node-RED],
  [iot-stat-reader], [`31800`], [API backendu],
  [iot-stat-frontend], [`31900`], [Panel użytkownika],
)

== GitOps z zachowawczą synchronizacją

Każdy katalog obciążenia w `infrastructure/manifests/` jest jedną aplikacją ArgoCD
(`Application`), wszystkie wskazujące na to repozytorium. Polityka synchronizacji jest
`automated`, ale z `prune: false` i `selfHeal: false`: ArgoCD aplikuje nowe commity, lecz
nigdy nie usuwa zasobów usuniętych z Gita ani nie cofa ręcznych zmian na klastrze. Dla
projektu dydaktycznego, przy którym dłubiemy ręcznie, jest to bezpieczniejsze niż pełne
samoleczenie. Rejestracje `Application`, przestrzeń nazw i polityka Viz są aplikowane raz przez
playbook konfiguracyjny, bo muszą istnieć, zanim ArgoCD cokolwiek zsynchronizuje do
przestrzeni.

#figpic("images/argocd_applications.png",
  [ArgoCD: wszystkie pięć aplikacji uzgodnione do stanu Synced / Healthy.])

= Automatyzacja

Cała platforma sterowana jest z głównego pliku `Makefile`. Provisioning węzłów to jedyny
krok dotykający maszyn przez SSH; cała reszta działa lokalnie wobec API klastra, używając
naszych własnych `kubectl` i `linkerd`.

#table(
  columns: (auto, 1fr),
  stroke: 0.5pt,
  fill: head-fill,
  [*Cel*], [*Co robi*],
  [`make setup_mk8s`], [Provisioning MicroK8s na maszynach przez SSH: instalacja snap, włączenie dodatków, dołączenie węzłów roboczych, konfiguracja generatora obciążenia, instalacja CRD-ów Gateway API.],
  [`make set_all_up`], [Lokalnie: instalacja Linkerd, potem Viz, utworzenie przestrzeni i polityki Viz, utworzenie sekretów z `.env`, instalacja ArgoCD, rejestracja i synchronizacja wszystkich pięciu aplikacji.],
  [`make setup_everything`], [`setup_mk8s`, potem `set_all_up`, potem `bootstrap_chirpstack`: cała platforma jednym poleceniem.],
  [`make bootstrap_chirpstack`], [Provisioning najemcy ChirpStack, aplikacji, profili urządzeń z kodekami, bramy i urządzeń. Idempotentne; `DRY_RUN=true` podgląda zmiany.],
  [`make teardown`], [Usuwa wszystkie usługi, ArgoCD, Linkerd Viz i Linkerd. Same węzły pozostają nietknięte.],
  [`make nodered_export`], [Zapisuje aktualne przepływy Node-RED z powrotem do Gita, z wyczyszczonym hasłem.],
  [`make status`], [Aplikacje ArgoCD, pody `iot-system` i krawędzie siatki w skrócie.],
)

== Provisioning klastra (`setup-microk8s.yaml`)

To ten playbook, który działa przez SSH, wobec grupy inwentarza `microk8s_cluster`.
Instaluje snapd i MicroK8s na każdym węźle, dodaje użytkownika do grupy `microk8s` i czeka,
aż węzeł zgłosi gotowość. Na warstwie sterowania włącza dodatki `dns`, `hostpath-storage` i
`community`. Węzły robocze są dołączane pojedynczo (`serial: 1`), ponieważ dołączanie ich
równolegle może wywołać wyścigi w dqlite; warstwa sterowania generuje świeży token
dołączenia dla każdego z nich. Generator obciążenia dostaje k6 z oficjalnego repozytorium
apt. Na koniec playbook eksportuje kubeconfig MicroK8s i instaluje CRD-y Gateway API, których
potrzebuje Linkerd.

== Uruchamianie siatki i aplikacji (`setup-all.yml`)

Ten playbook działa lokalnie (`connection: local`). Zaczyna od kontroli wstępnych, że
`kubectl` może dosięgnąć klastra i że dostępne jest CLI `linkerd`. Linkerd nie jest
idempotentny przy ponownej instalacji, więc playbook najpierw sprawdza ConfigMap
`linkerd-config` i instaluje CRD-y oraz warstwę sterowania tylko, gdy jej nie ma; tak czy
inaczej uruchamia `linkerd check` jako bramkę przed dalszymi krokami. Ten sam wzorzec
instaluje Linkerd Viz. Następnie aplikuje przestrzeń nazw i politykę autoryzacji Viz, tworzy
dwa sekrety z `.env` (kończąc wcześnie czytelnym komunikatem, jeśli brak `.env`) i instaluje
ArgoCD z użyciem server-side apply (CRD ApplicationSet jest zbyt duży dla adnotacji
client-side, której użyłby zwykły apply). Po gotowości głównych komponentów ArgoCD rejestruje
pięć aplikacji, wyzwala natychmiastową synchronizację dla każdej zamiast czekać na odpytanie i
na koniec blokuje się, aż każda aplikacja zgłosi `Synced/Healthy`.

== Provisioning urządzeń (`bootstrap-chirpstack.yml`)

Sam ChirpStack jest konfigurowany przez `infrastructure/chirpstack/bootstrap.py`,
deklaratywny i idempotentny provisioner. Czyta `devices.yaml` (najemca, aplikacja, profile
urządzeń z kodekami JS, brama i urządzenia) oraz klucze OTAA ze środowiska, a następnie
uzgadnia ChirpStack po natywnym gRPC. Loguje się jako admin, aby uzyskać własny token API,
więc nigdy nie musimy wcześniej tworzyć klucza. To jest powód, dla którego port
`chirpstack-api` jest opaque w siatce, ponieważ skrypt mówi natywnym gRPC. Playbook buduje
virtualenv dla skryptu, ponawia bootstrap kilka razy (ChirpStack nie ma sondy gotowości, więc
API może nie być od razu dostępne po `set_all_up`) i może działać w trybie podglądu.

#figpic("images/chirpstack_dashboard.png",
  [Panel najemcy ChirpStack po bootstrapie: brama pokazuje się jako online, a urządzenia
  oraz zużycie data-rate są śledzone.])

== Usuwanie (`teardown.yml`)

Usuwanie odwraca konfigurację i toleruje to, że coś już zniknęło (`--ignore-not-found`,
`failed_when: false`), więc można je bezpiecznie uruchamiać wielokrotnie. Usuwa aplikacje
ArgoCD, kasuje całą przestrzeń `iot-system` (zabierając ze sobą wszystkie obciążenia, usługi,
polityki i sekrety), odinstalowuje Viz i warstwę sterowania Linkerd oraz kasuje przestrzeń
`argocd`. Węzły klastra pozostają nietknięte, więc `make set_all_up` odtwarza potem wszystko
z Gita i `.env`.

#note[
  *Jedno fizyczne zastrzeżenie przy odtwarzaniu.* Usunięcie ChirpStack czyści jego magazyn
  sesji urządzeń. Prawdziwe czujniki OTAA wciąż trzymają starą sesję i nadal wysyłają ramki
  danych, które świeży serwer odrzuca, dopóki urządzenia nie dołączą ponownie (po odcięciu
  zasilania lub po przekroczeniu progu ponownego dołączenia). To właściwość LoRaWAN, a nie
  naszej automatyzacji.
]

= Weryfikacja i dowody

To część, która podpiera twierdzenia o bezpieczeństwie. Celem jest pokazanie trzech rzeczy:
że ruch między podami jest naprawdę szyfrowany na łączu, że polityka domyślnej blokady
faktycznie odrzuca rozmówców, których nie autoryzowaliśmy, oraz że sam Linkerd raportuje
zarówno szyfrowanie, jak i autoryzację na rzeczywistych żądaniach.

== Dowód A: ruch jest szyfrowany na łączu

Wewnątrz poda w siatce są dwa przeskoki sieciowe. Aplikacja rozmawia z własnym proxy Linkerd
przez pętlę zwrotną (`lo`), tekstem jawnym, na własnym porcie aplikacji. Proxy rozmawia
następnie z proxy zdalnego poda przez prawdziwy interfejs sieciowy (`eth0`) i ten przeskok
to TLS, docierający na port wejściowy proxy 4143. Jeśli więc przechwycimy oba interfejsy
wewnątrz docelowego poda i poszukamy znanego znacznika, powinien pojawić się na `lo` i nigdy
na `eth0`.

Publikujemy wiadomość MQTT niosącą znacznik `SECRET-PAYLOAD-12345` od autoryzowanego klienta,
a następnie przechwytujemy ruch wewnątrz poda `mosquitto`:

```bash
# (1) pętla zwrotna: aplikacja <-> proxy. Znacznik jest czytelny.
tcpdump -l -n -i lo   -A 'tcp port 1883' | grep SECRET-PAYLOAD     # wypisuje wiadomość
# (2) na łączu: proxy <-> zdalne proxy. Zaszyfrowane, znacznik się nie pojawia.
tcpdump -l -n -i eth0 -A 'tcp port 4143' | grep SECRET-PAYLOAD     # pozostaje ciche
```

Pierwsze polecenie wypisuje ładunek; drugie nie wypisuje nic. To samo przechwycenie otwarte
w Wireshark pokazuje stronę łącza jako `TLSv1.3` `Application Data`, a uzgadnianie niesie
zarówno certyfikat klienta, jak i serwera, co stanowi „wzajemność” we wzajemnym TLS.

#figpic("images/tcpdump_app_to_proxy.png",
  [Przechwycenie na pętli zwrotnej (`lo`) wewnątrz poda mosquitto: znacznik
  `SECRET-PAYLOAD-12345` jest wyraźnie czytelny na przeskoku aplikacja–proxy.])

#figpic("images/tcpdump_proxy_to_remoteproxy.png",
  [Ten sam ruch na interfejsie sieciowym (`eth0`, port 4143): przechwycono 420 pakietów,
  ale `grep` znacznika nie znajduje nic. Ładunek jest zaszyfrowany.])

#figpic("images/TLS_mqtt_mosquitto.png",
  [Przechwycenie z łącza otwarte w Wireshark: strumień to `TLSv1.3` Application Data, bez
  czytelnej treści MQTT.])

== Dowód B: polityka odrzuca nieautoryzowanych rozmówców

Polityka autoryzacji `mosquitto` dopuszcza tylko cztery tożsamości. Aby pokazać, że
cokolwiek innego jest odrzucane, uruchamiamy poda na koncie ServiceAccount `default`, który
jest w siatce (ma więc poprawną tożsamość), ale nie jest na liście dozwolonych, i każemy mu
spróbować opublikować:

```
$ kubectl exec -n iot-system rogue -c rogue -- \
    mosquitto_pub -h mosquitto -t demo/secret -m SHOULD-BE-BLOCKED
Error: The connection was lost
command terminated with exit code 7
```

Połączenie jest zrywane, zanim wymieniona zostanie jakakolwiek ramka MQTT. Proxy docelowe
loguje dokładnie dlaczego:

```
INFO inbound:server{port=4143}: linkerd_app_inbound::policy::tcp: Connection denied
     server.name=mosquitto-mqtt
     tls=Some(Established { client_id: ...Name("default.iot-system.serviceaccount...") })
```

Szczegół, który ma tu znaczenie: `tls=Established` oznacza, że mTLS *się powiódł* i rozmówca
został pozytywnie zidentyfikowany jako konto `default`. Połączenie i tak zostało odrzucone,
ponieważ tożsamość i autoryzacja to oddzielne warstwy. Poprawna tożsamość w siatce nie
wystarcza; polityka musi ją wskazać. Metryki proxy potwierdzają ten podział: licznik odmów
rośnie dla nieautoryzowanej tożsamości, podczas gdy liczniki dopuszczeń rosną dla legalnych
klientów:

```
inbound_tcp_authz_allow_total{... client_id="mqtt-client.iot-system..."}  2339
inbound_tcp_authz_deny_total {... client_id="default.iot-system..."}         1
```

#figpic("images/unauthorized_client_rogue.png",
  [Nieautoryzowany pod `rogue` (na koncie ServiceAccount `default`) próbuje publikować i
  kończy się błędem `Error: The connection was lost`, kod wyjścia 7.])

#figpic("images/denial_log_proof_b.png",
  [Log proxy docelowego: połączenie jest odrzucone dla serwera `mosquitto-mqtt`, mimo że
  `tls=Established` zidentyfikowało rozmówcę jako konto `default`.])

#figpic("images/deny_counter_proof_b.png",
  [Liczniki autoryzacji proxy: licznik odmów rośnie dla nieautoryzowanej tożsamości,
  podczas gdy liczniki dopuszczeń rosną dla czterech legalnych klientów.])

#note[
  Ponieważ MQTT działa na porcie opaque (surowy TCP), odmowa następuje na poziomie
  połączenia: proxy zrywa połączenie TCP w trakcie kontroli autoryzacji, zanim wysłana
  zostanie choć jedna ramka MQTT. Nie ma „odrzuconej ramki”, jest odrzucone połączenie. Dla
  usługi HTTP ta sama odmowa byłaby zamiast tego odpowiedzią `403` na żądanie.
]

== Dowód C: własne poświadczenie Linkerd

Dwa pierwsze dowody patrzą na łącze i na politykę. Trzeci używa własnego widoku Linkerd, by
potwierdzić, że codzienny, autoryzowany ruch jest zarówno szyfrowany, jak i poprawnie
autoryzowany.

`linkerd viz edges` wypisuje każde połączenie w przestrzeni nazw i to, czy jest
zabezpieczone. Każda krawędź pokazuje znak zabezpieczenia:

```
SRC                        DST         ...  SECURED
nodered                    mosquitto   ...  √
chirpstack                 redis       ...  √
chirpstack-gateway-bridge  mosquitto   ...  √
...                                         (każda krawędź √)
```

`linkerd viz tap` schodzi do pojedynczych żądań. Na rzeczywistym żądaniu z frontendu do
readera Linkerd raportuje, że żądanie przeszło przez mTLS, podaje zweryfikowaną tożsamość
klienta i wskazuje politykę, która je autoryzowała:

```
req ... tls=true :method=GET :path=/
    src_client_id=iot-stat-frontend.iot-system.serviceaccount.identity.linkerd.cluster.local
    dst_authz_name=allow-external-to-iot-stat-reader
```

Dla kontrastu ruch przychodzący spoza siatki (na przykład sonda zdrowia kubeletu, która
pochodzi z węzła) jest w tap oznaczany jako `tls=no_tls_from_remote`, co ułatwia odróżnienie
ścieżek w siatce i poza nią.

#figpic("images/linkerd_mtls_meshed_edge.png",
  [`linkerd viz edges`: każda krawędź pod–pod w `iot-system` jest raportowana jako
  zabezpieczona.])

#figpic("images/tls_is_true__verified_client_identity__authorizing_policy.png",
  [`linkerd viz tap`: pojedyncze żądanie pokazujące `tls=true`, zweryfikowaną tożsamość
  klienta i politykę autoryzującą.])

#figpic("images/linkerd-viz-gui.png",
  [Panel Linkerd Viz dla przestrzeni `iot-system`: każde obciążenie jest w siatce (1/1) ze
  100% skutecznością.])

== Dowód D: potok faktycznie przenosi dane

Na koniec, bezpieczeństwo nie miałoby sensu, gdyby żadne dane nie płynęły. Prawdziwe uplinki
lądują w tabeli `device_uplinks`, którą możemy policzyć wprost:

```bash
kubectl exec -n iot-system postgres-0 -c postgres -- \
  psql -U chirpstack -d chirpstack -c "SELECT count(*) FROM device_uplinks;"
```

a panel renderuje je jako szeregi czasowe per urządzenie oraz tabelę ostatnich uplinków.

#figpic("images/iot-stats-frontend.png",
  [Panel iot-stat-frontend (Wykresy): szeregi czasowe per urządzenie dla trzech czujników,
  w tym pola kategoryczne, takie jak naciśnięcie przycisku i stan oświetlenia dziennego.])

#figpic("images/iot-stats-frontend-uplinks.png",
  [Widok Uplinks: najnowsze zdekodowane uplinki zapisane w tabeli `device_uplinks`.])

