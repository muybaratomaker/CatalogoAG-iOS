# Catalogo AG iOS 2.3 — Home e modulo aggiunta rinnovati

Basato sulla versione 2.2 funzionante, senza modifiche alle API Cloudflare, al CSV o alla logica amministrativa.

## Home
- Film e Serie TV sono ora due pulsanti grandi, con contatore aggiornato e copertina TMDb sfumata; aprono direttamente la relativa sezione.
- Da vedere è un terzo pulsante più grande, con sfondo dedicato, che apre la lista.
- Altezza delle card calcolata in base allo spazio dello schermo; su dispositivi compatti la pagina può scorrere verticalmente.
- Se l'immagine non è disponibile compare una sfumatura blu, senza bloccare la pagina.

## Aggiunta
- Form con pannelli arrotondati in stile Catalogo AG; ricerca TMDb, scelta risultato, inserimento manuale, controllo duplicati e salvataggio rimangono invariati.

## Icona
- Il workflow GitHub Actions scarica la favicon pubblica del sito (favicon.png) e la converte in un'icona iOS 1024 × 1024 senza trasparenza. Se il download fallisce usa una icona AG di riserva, senza impedire la build.
- LiveContainer può mostrare anche una propria icona nella sua interfaccia: la personalizzazione dell'icona dell'app sulla schermata Home dipende dalle modalità di installazione.

## Come aggiornare
Sostituire sul repository i file `CatalogoAG/CatalogoAGApp.swift`, `project.yml`, `.github/workflows/build.yml` e aggiungere `CatalogoAG/Assets.xcassets/AppIcon.appiconset/Contents.json`. Non caricare soltanto lo Swift: i file aggiuntivi servono all'icona.

## Verifiche
`swiftc -frontend -parse` verifica la sintassi; la compilazione iOS vera va confermata da GitHub Actions.
