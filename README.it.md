<p align="center">
  <img src="docs/images/icon.png" width="128" alt="Icona di Vedetta">
</p>

<h1 align="center">Vedetta</h1>

<p align="center">
  <b>L'app nativa e veloce per Mac per le tue telecamere e i tuoi NVR.</b><br>
  Diretta, registrazioni con calendario e timeline, esportazione MP4, eventi e notifiche.<br>
  TP-Link VIGI · Hikvision · Dahua · Reolink · Uniview · qualsiasi dispositivo ONVIF o RTSP.
</p>

<p align="center"><a href="README.md">English</a> · <a href="README.fr.md">Français</a></p>

---

Vedetta sostituisce i pesanti programmi di videosorveglianza per Windows (spesso usati sul Mac tramite
Wine/CrossOver) con un'app davvero nativa: decodifica video hardware, interfaccia Liquid Glass per
macOS 26 e consumi minimi — **16 telecamere in diretta al 10–13 % di CPU** su un Mac Apple Silicon.

## Funzioni

- **Diretta** — griglie da 1, 4, 6, 8, 9 e 16 riquadri, pagine e giro automatico, trascina un riquadro su un
  altro per scambiare le telecamere, schermo intero, finestre separate per altri monitor, zoom digitale, audio.
  I riquadri piccoli usano il flusso leggero, quelli ingranditi l'alta qualità; **istantanee e registrazioni usano
  sempre il flusso a qualità massima**. Nomi delle telecamere sempre / al passaggio / mai; immagine intera,
  riempita o allungata (senza tagliare l'orologio della telecamera).
- **Registrazioni** — calendario con i giorni registrati, timeline di 24 ore con zoom, pause di
  registrazione ed eventi colorati (movimento, persone, veicoli, attraversamento linea, intrusione…),
  riproduzione sincronizzata fino a 4 telecamere, pausa, fotogramma per fotogramma, ±10 s, evento
  precedente/successivo, velocità se supportata. **Scorciatoie da tastiera** (tasti singoli) e **uso con una
  mano sola**: la rotella fa lo zoom della timeline attorno al puntatore, i pulsanti fanno zoom, scorrono e
  impostano la selezione.
- **Esportazione MP4** — salva qualsiasi intervallo o singolo evento sul Mac **senza ricodifica**, con o senza audio, con coda,
  avanzamento, annullamento, nuovo tentativo e ripresa dopo il riavvio.
- **Eventi e notifiche** — elenco giornaliero con filtri e notifiche macOS; un clic riporta al momento.
- **PTZ** — joystick, zoom, velocità e posizioni salvate per le telecamere ONVIF motorizzate.
- **Dispositivi** — ricerca automatica in rete, configurazione in una schermata, rinomina/nascondi canali,
  interfaccia web del dispositivo dentro l'app per le impostazioni avanzate.
- **Sicura per gli account del registratore** — una sola sessione per registratore, un solo tentativo di
  accesso alla volta, nessun login mentre il registratore non risponde (solo verifiche senza password con
  pause crescenti); una password rifiutata o un utente bloccato fermano ogni tentativo automatico: l'NVR non
  blocca l'utente né fa suonare il cicalino per colpa di Vedetta. Esci / Cambia utente dal menu o dalle Impostazioni.
- **Efficiente e riservata** — gli stream si fermano quando la finestra è nascosta; password nel
  Portachiavi; nessun account, nessun cloud, nessuna telemetria.
- **Impostazioni durature** — salvate mentre le cambi, leggibili tra versioni diverse (un file danneggiato viene
  messo da parte e si usa il backup), File › Esporta/Importa impostazioni (tutto tranne le password).
- **Multilingua** — italiano, inglese, francese: segue la lingua di macOS e si può cambiare nelle Impostazioni.

## Dispositivi supportati

| Dispositivo | Diretta | Registrazioni | Eventi |
|---|:-:|:-:|:-:|
| NVR **TP-Link VIGI** | ✓ | ✓ | ✓ + notifiche |
| **NVR ONVIF di qualsiasi marca** (Hikvision, Dahua, Uniview, Reolink…) | ✓ | ✓ con ONVIF Profile G | ✓ + notifiche |
| NVR **Hikvision / Dahua** senza ONVIF (RTSP) | ✓ | ✓ scegliendo l'orario | – |
| NVR **Reolink / Uniview** senza ONVIF (RTSP) | ✓ | – | – |
| **Telecamere ONVIF** di qualsiasi marca, anche PTZ | ✓ + PTZ | ✓ se registrano (Profile G) | ✓ |
| Qualsiasi flusso **RTSP** | ✓ | – | – |

## Protezione dell'account

I registratori bloccano un utente (e spesso fanno suonare il cicalino) dopo pochi accessi falliti. Vedetta è
fatta per non causarlo mai:

- **Una sola sessione per registratore**, condivisa da diretta, registrazioni, eventi ed esportazioni. Il
  video parte solo dopo che le credenziali sono state confermate.
- **I problemi di rete non causano mai login.** Se il registratore non risponde, Vedetta lo verifica senza
  inviare la password, dopo 5 s, 10 s, 20 s… fino a 5 minuti, e riusa la sessione quando torna.
- **Un tentativo alla volta**: le funzioni non fanno mai login in parallelo.
- **Password rifiutata o utente bloccato → stop totale**, fino a un nuovo accesso o all'orario di sblocco
  indicato dal registratore. Vedetta spiega il motivo e mostra la schermata di accesso.
- **Esci / Cambia utente** (menu dell'app, Impostazioni › Account, scheda del dispositivo) chiude il video,
  termina la sessione sul registratore (solo in locale se non è raggiungibile o l'utente è bloccato), cancella
  la password salvata e torna alla schermata di accesso.
- **Registro connessioni** con ora, esito e codice di errore di ogni tentativo, senza password:
  `~/Library/Application Support/Vedetta/Logs/connections.log` (Impostazioni › Account).

**Usa un utente dedicato**: crea sul registratore un utente solo per Vedetta con i soli permessi di diretta
e riproduzione, invece di `admin`. Così l'account admin e le app del registratore restano al sicuro.

## Requisiti e installazione

macOS 26 o successivo, Mac con Apple Silicon.

1. Scarica `Vedetta-x.y.z-macOS.dmg` dall'[ultima release](https://github.com/TX-Breaker/vedetta/releases/latest).
2. Trascina **Vedetta** in **Applicazioni**.
3. Se macOS dice che non può verificare lo sviluppatore: clic destro su Vedetta → **Apri**
   (oppure `xattr -dr com.apple.quarantine /Applications/Vedetta.app`).
4. Consenti l'accesso alla **Rete locale** quando macOS lo chiede.
5. Scegli cosa collegare, inserisci la password: fatto.

## Compilare dal sorgente

```bash
git clone https://github.com/TX-Breaker/vedetta.git && cd vedetta
scripts/build-app.sh --install
```

Test: `swift test` e `scripts/regression.sh` (servono `brew install mediamtx ffmpeg`).
Traduzioni: `Resources/Localization/strings.tsv` + `python3 scripts/l10n.py`.

## Avvertenza

Vedetta è un progetto open source indipendente, **non affiliato né approvato** da TP-Link, Hikvision, Dahua,
Reolink, Uniview, EZVIZ o ONVIF. I marchi appartengono ai rispettivi proprietari e sono citati solo per
indicare la compatibilità.

Licenza [MIT](LICENSE).
