# KubeContext für Omarchy

Zeigt den aktiven `kubectl`-Context in der Bar, wechselt ihn per Klick und gibt
einen kurzen Überblick über den gewählten Cluster.

*(English version: [README.md](README.md) — die maßgebliche Fassung.)*

![Vorschau](preview.png)

- **Bar** — der Name des aktuellen Contexts neben einem Kubernetes-Icon, damit
  nie geraten werden muss, gegen welchen Cluster der nächste Befehl läuft.
- **Contexts** — jeder Context der kubeconfig mit API-Server, Namespace und
  Erreichbarkeit. Ein Klick wechselt.
- **Cluster** — bereite Nodes, Rollen, laufende Pods, Namespaces, Server- und
  Kubelet-Version, dazu CPU und Speicher im Mittel, sofern ein Metrics-Server
  antwortet.

## Warum es nicht im Weg steht

Eine kubeconfig zu lesen ist ein lokaler Dateizugriff und kostet nichts. Das
Label in der Bar folgt einem Context, den du im Terminal gewechselt hast, daher
innerhalb von Sekunden.

Mit einem Cluster zu reden ist das Gegenteil. Cluster scheitern auf mehr Arten
als sie gelingen — ein Credential-Plugin, das einen Fehler wirft, ein privater
Endpunkt, dessen DNS nicht auflöst, ein API-Server, der schlicht nie antwortet —
und dieses Widget läuft in dem Prozess, der deinen Desktop zeichnet. Also:

- Solange das Panel zu ist, verlässt nichts die Maschine.
- Jeder Aufruf ist doppelt begrenzt, durch `kubectl --request-timeout` und durch
  ein äußeres `timeout`. Ein toter Cluster kostet damit Sekunden statt ewig.
- Die Erreichbarkeit aller Contexts wird parallel geprüft. Es wartet also der
  langsamste, statt der Summe aller.
- Ein Cluster, der nicht antwortet, wird als nicht erreichbar gemeldet, nie als
  leerer Cluster mit null Nodes und null Pods.

## Voraussetzungen

`kubectl` im `PATH` und eine lesbare kubeconfig. Sonst nichts. Fehlt `kubectl`,
sagt das Panel das, statt eine leere Liste zu zeigen.

## Installation

```bash
omarchy plugin add https://github.com/Nepomuk-Software/KubeWidget.git --enable
```

## Was es schreibt

Eine einzige Sache, und nur auf ausdrücklichen Klick:
`kubectl config use-context <name>`, was `current-context` in deiner kubeconfig
setzt. Jede Shell, die du danach öffnest, erbt ihn — genau darum geht es, und
genau deshalb passiert es nie von allein. Alles andere, was das Widget tut, ist
lesend.

## Bedienung

| Ort | Aktion |
|---|---|
| Bar, links | Panel auf/zu |
| Bar, rechts oder mitte | alles sofort neu einlesen |
| Panel, Klick auf einen Context | dorthin wechseln |
| Panel, `r` | neu einlesen |
| Panel, Esc | Panel schließen |

## Einstellungen

`omarchy bar set io.github.nepomuk-software.kubecontext <key> <value>`

| Key | Vorgabe | Wirkung |
|---|---|---|
| `showContext` | `true` | Context-Name neben dem Icon; auf vertikalen Bars ohne Wirkung |
| `maxLabel` | `18` | längere Namen werden in der Bar gekürzt |
| `contextIntervalSec` | `5` | wie oft die kubeconfig neu gelesen wird (lokal, kein Netz) |
| `probeIntervalSec` | `30` | wie oft Cluster kontaktiert werden, solange das Panel offen ist |

## IPC

```
omarchy-shell io.github.nepomuk-software.kubecontext <method> [context]
```

| Methode | Tut |
|---|---|
| `open` `close` `toggle` | das Popup |
| `current` | Name des aktiven Contexts |
| `use <context>` | zu einem Context wechseln |
| `refresh` | kubeconfig neu lesen, Erreichbarkeit prüfen, Überblick holen |
| `status` | `<context> reachable <version> nodes=r/t pods=r/t ns=n`, sonst `unreachable`, `unprobed`, `no kubectl` |

## Lizenz

MIT — siehe [LICENSE](LICENSE). Plugins laufen unsandboxed im Omarchy-Shell-
Prozess; lies den Code, bevor du ihn installierst.
