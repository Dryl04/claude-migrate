# claude-migrate — Migration de projets Claude Code vers un serveur

Outil de migration d'un projet Claude Code (code + historique de
conversations + configuration Claude) depuis le PC local vers un serveur
distant, puis de resynchronisation.

Né d'un besoin concret : délocaliser le développement sur un VPS sans perdre
l'historique des conversations Claude Code. N'importe quel projet, n'importe
quel serveur.

---

## Contenu du dossier

```
claude-migrate/
├── README.md                    ce document
├── migrate-claude-project.sh    le script (exécutable)
└── config/                      créé au premier lancement (non versionné)
    ├── servers.conf             profils de serveurs mémorisés
    └── logs/                    un journal horodaté par exécution
```

Tout vit à côté du script : le déplacer déplace l'outil complet.
Les profils de `servers.conf` servent de défauts (hôte, utilisateur, port,
racine des projets, dossier de config Claude) pour ne rien retaper.

---

## Prérequis

**En local** : `bash`, `ssh`, `rsync` (indispensables) ; `python3`
(recommandé — sert à retrouver le chemin local des sessions) ;
`numfmt` (facultatif, affichage des tailles). Si un jour le repli par mot de
passe est utilisé, `sshpass` sera proposé à l'installation.

**Sur le serveur** : rien d'obligatoire au départ — le script détecte ce qui
manque (`rsync`, `tmux`, `mosh`, `git`, `node`, `npm`, `claude`, `supabase`)
et propose de l'installer avec votre accord (voir « Installations »).
Seule exception : `rsync` côté serveur est **bloquant** — sans lui, la
migration s'arrête proprement.

---

## Démarrage rapide

```bash
cd ~/claude-migrate

./migrate-claude-project.sh --list     # voir projets et profils connus
./migrate-claude-project.sh           # migration interactive, questions au fil de l'eau
```

**Recommandation** : pour un premier envoi vers un serveur inconnu, faire
d'abord un passage en simulation :

```bash
./migrate-claude-project.sh --dry-run
```

Tout se déroule comme une vraie migration (menus, vérifications, récapitulatif)
mais **rien n'est écrit sur le serveur**.

---

## Les trois modes

### 1. Interactif (par défaut)

```bash
./migrate-claude-project.sh [--dry-run]
```

Le script pose chaque question avec un défaut entre crochets — la touche
Entrée garde le défaut. Ordre des étapes :

1. **Projet** — liste des projets détectés par leurs sessions Claude
   (comptes `~/.claude` et, s'il existe, `~/.claude-work` — voir « Deux
   comptes Claude » —, triés par activité),
   ou saisie d'un chemin quelconque.
2. **Dossier à copier** — Entrée = le projet lui-même ; indiquer le parent
   pour tout inclure (ex. `mon-app/` complet plutôt que `mon-app/project/`).
   Les sessions restent rattachées au dossier de travail, pas au dossier copié.
3. **Exclusions** — motifs rsync supplémentaires (ex. `images/ *.zip`).
   Exclusions fixes : `node_modules/`, `dist/`, `build/`, `.next/`, `.venv/`,
   `venv/`, `__pycache__/`, `.pytest_cache/`, `target/`, `*.log`.
4. **Serveur** — profils mémorisés, alias `~/.ssh/config`, ou saisie
   `user@host[:port]` (voir « Connexions »).
5. **Destination** — racine des projets (défaut du profil, sinon `~/projets`),
   nom du dossier, dossier de travail (là où `claude` sera lancé : c'est la clé
   des sessions), dossier de config Claude (défaut `~/.claude`).
6. **Outils du serveur** — détection, installations proposues (voir plus bas).
7. **Config globale** — agents/commandes/skills/settings, oui ou non.
8. **Récapitulatif + confirmation** — dont la liste des fichiers sensibles
   détectés (`.env`, clés) : ils **sont** transférés car nécessaires au projet.
9. **Transfert** — code, sessions, config globale.
10. **Dépendances** — `npm ci`/`npm install` (racine + sous-dossiers node),
    `pip install` si `requirements.txt`.
11. **Vérification** — état du serveur après migration.
12. **Profil** — mémorisation du serveur pour la prochaine fois.

### 2. Inventaire

```bash
./migrate-claude-project.sh --list
```

Affiche les projets locaux détectés (comptes, nombre de sessions, taille)
et les profils de serveurs, puis quitte. Aucune connexion.

### 3. Non-interactif

```bash
./migrate-claude-project.sh --yes --project <chemin> --server <cible|profil> [options]
```

Toutes les questions prennent leur valeur par défaut. Exige `--project` et
`--server`. La connexion par mot de passe y est impossible : il faut une clé
déjà installée. Pratique pour resynchroniser un projet déjà migré :

```bash
# resynchronisation du code d'un projet déjà migré (sessions+config en place)
./migrate-claude-project.sh --yes \
    --project ~/dev/mon-app \
    --server vps --no-globals
```

### Options

| Option | Effet |
|---|---|
| `--project <chemin>` | dossier de travail du projet (celui des sessions) |
| `--server <cible>` | `user@host`, `user@host:port`, alias ssh, ou **nom de profil** |
| `--port <N>` | port ssh, si la cible n'en contient pas |
| `--account <compte>` | `claude` (perso), `claude-work` (pro) ou `both` — quelles sessions migrer |
| `--dest-root <chemin>` | racine des projets sur le serveur (ex. `~/projets`) |
| `--no-globals` | ne pas copier agents/commandes/skills/settings |
| `--yes` | mode non-interactif |
| `--dry-run` | simulation : rien n'est écrit sur le serveur |
| `--list` | inventaire projets + profils, puis quitte |
| `--help` | aide intégrée |

---

## Deux comptes Claude (optionnel)

Le script lit les sessions de `~/.claude` (configuration par défaut) et de
`~/.claude-work`, un second compte isolé que l'on obtient avec un alias :

```bash
alias claude-work='CLAUDE_CONFIG_DIR="$HOME/.claude-work" claude'
```

Sans second compte, rien à faire : le dossier absent est simplement ignoré.
`--account claude` / `claude-work` / `both` filtre les sessions migrées.

---

## Connexions

Le script essaie d'abord l'authentification **par clé** (silencieuse). En cas
d'échec, il propose la chaîne suivante :

1. **ssh-copy-id** — votre clé publique est installée sur le serveur, le mot
   de passe est demandé **une seule fois**. Si aucune clé locale n'existe,
   une paire ed25519 est générée (avec accord). C'est la solution durable.
2. **sshpass** (si ssh-copy-id échoue ou est refusé) — le mot de passe,
   demandé en début de session, est utilisé pour chaque commande. Il est
   proposé d'installer `sshpass` localement si absent. Moins sûr (le mot de
   passe transite par la ligne de commande) : à réserver aux serveurs qui
   refusent l'authentification par clé.

Cas couverts : clé déjà présente, alias `~/.ssh/config` (proposés en menu),
`user@host`, `user@host:port`, `--port`, mot de passe.

---

## Installations proposées sur le serveur

Toutes demandent une confirmation, et n'ont jamais lieu en `--dry-run` :

| Outil | Comment | Condition |
|---|---|---|
| `rsync`, `tmux`, `mosh`, `git` | apt / dnf / pacman (`sudo`) | absents. sudo sans mot de passe, sinon prompt interactif |
| `node` + `npm` | tarball officiel nodejs.org → `~/.local/node`, liens dans `~/.local/bin` | absents **et** projet node (`package.json`). Sans sudo |
| Claude Code | `npm install -g @anthropic-ai/claude-code` + lien binaire | absent |
| CLI `supabase` | `npm install -g supabase` + lien binaire | absent **et** dossier `supabase/` dans le projet |

Le **login** (Claude Code, `supabase login`) n'est jamais fait ni copié par
le script : il reste à faire manuellement sur le serveur, une seule fois.

---

## Ce qui est migré

- **Code** du dossier choisi, avec ses `.env` et fichiers non versionnés
  (ils sont nécessaires au projet ; ils sont listés avant transfert),
  dépôts `.git` compris. Exclusions standard + vos motifs.
- **Sessions** des comptes choisis → `<config>/projects/<chemin-encodé>/`.
  Le chemin est encodé comme le fait Claude Code (`/` → `-`) sur le
  dossier de travail **distant** déclaré à l'étape 5 : `claude --resume`
  les retrouve. Les sessions des deux comptes fusionnent sans collision
  (noms en UUID).
- **Config globale** (sauf `--no-globals`) : `agents/`, `commands/`,
  `skills/`, `settings.json`, `CLAUDE.md` — compte pro d'abord, compte
  perso ensuite (c'est lui qui porte les skills).

## Ce qui n'est jamais migré

- `.credentials.json` et `.claude.json` (jetons d'authentification) ;
- tout ce qui est exclu (voir motifs) ;
- rien n'est **supprimé** : rsync tourne sans `--delete` ;
- rien n'est **écrasé** côté serveur pour la config partagée :
  `--ignore-existing` (le serveur garde ses agents, skills, settings).

---

## Profils de serveurs

`config/servers.conf` — format :

```ini
[vps]
host=203.0.113.10
user=deploy
dest_root=~/projets
config_dir=~/.claude
# port=2222            (facultatif)
```

- Utilisation : `--server vps`, ou choix dans le menu interactif.
- Création/mise à jour : à la fin de chaque migration réussie (question
  « Mémoriser ce serveur ? »).
- Édition : c'est un fichier texte, modifiable/supprimable à la main.
  Le nom du profil proposé par défaut est dérivé de l'hôte — n'hésitez pas
  à renommer la section.

---

## Journaux

Chaque exécution écrit `config/logs/migrate-AAAA-MM-JJ-HHMMSS.log` :
sortie complète des commandes, erreurs détaillées, résumé final. En cas
d'échec d'une étape, le message renvoie à ce journal et la migration
continue les étapes indépendantes ; le résumé final liste tout ce qui a
échoué.

---

## Après la migration

Le rappel est affiché en fin de script, adapté aux outils disponibles :

```bash
mosh deploy@203.0.113.10         # connexion qui survit aux coupures
tmux new -s mon-app              # session persistante (ou tmux attach -t …)
cd ~/projets/mon-app && claude --resume
```

Et si le serveur est sur le tailnet Tailscale, pour voir le serveur de dev
depuis le PC :

```bash
npm run dev                      # sur le serveur, dans le dossier de travail
tailscale serve --bg 5173        # expose le port (5173 vite, 3000 next)
```

---

## Limites et points d'attention

- **Resynchronisation ≠ sauvegarde** : rsync sans `--delete` met à jour les
  fichiers portant le même chemin — travailler des deux côtés sans
  discipline peut mélanger les versions (git est votre ami).
- Le prompt sudo des installations serveur nécessite un vrai terminal ;
  en `--yes`, seuls les sudo sans mot de passe fonctionnent.
- `deno` est détecté mais pas auto-installé (le CLI Supabase récent
  l'embarque) ; un projet qui l'exige explicitement devra l'installer à la main.
- Le scénario mot de passe a été écrit et revu mais n'a pas encore été
  éprouvé sur un vrai serveur à mot de passe.

## Dépannage rapide

| Symptôme | Piste |
|---|---|
| « connexion SSH impossible » | Tailscale/réseau : `tailscale status`, puis `ssh user@host` à la main |
| Sessions invisibles via `claude --resume` | le dossier de travail distant déclaré ne correspond pas à celui où `claude` est lancé — les sessions sont dans `<config>/projects/<chemin encodé>` |
| `rsync` échoue côté serveur | `rsync` absent sur le serveur → l'installer (`apt install rsync`) |
| Outil installé mais « absent » au contrôle | lien manquant dans `~/.local/bin` du serveur (voir journaux), ou shell de login sans ce PATH |
| Une étape échoue | lire le journal indiqué dans le message ; les étapes suivantes ont continué |