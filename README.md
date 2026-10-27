# Andy's Chat

A [Lovely](https://github.com/ethangreen-dev/lovely-injector) mod that shows your Twitch chat in Balatro, in the bottom-right corner where the deck sits. It's the chat [andy_balatro](https://twitch.tv/andy_balatro) streams with.

- **Every emote**: Twitch, [FrankerFaceZ](https://www.frankerfacez.com), [BetterTTV](https://betterttv.com) and [7TV](https://7tv.app) emotes (animated and zero-width ones included), Twitch's cheermotes (`Cheer100` and so on; a channel's custom ones stay text) and Unicode emoji, drawn with [Twemoji](https://github.com/jdecked/twemoji). FrankerFaceZ, BetterTTV and 7TV emotes are the global ones plus the channel's.
- **Events**: subs, gifted subs, raids, watch streaks, announcements, cheers and first messages show with a coloured bar and a line saying what happened, above the viewer's message.
- **Replies** show what they answer above them, cut to one line: `@viewer: their message`.
- **Channel point redemptions**, with the reward's name, once the game is linked (below).
- Messages deleted by moderators and banned users' messages disappear.

Chat is read anonymously, so it works without signing in to anything. Type your channel in the **Chat** tab of the game's settings (Options → Settings).

The deck still works under the panel: the button at the bottom shows the deck's name and how many cards are left, and opens the deck view. **F7** hides the chat and brings the normal deck back (and shows the chat again), **F8** clears it. In the Chat tab you can change both keys (click a shortcut, press the keys, and let go; Esc clears it) and how tall the panel is. It's made for a 16:9 window. In narrower ones the chat gets cut off at the screen's edge.

The chat covers the right margin, where the game stacks skip tags, so the mod moves them to the left margin. That's [Left Tags](https://github.com/andy-balatro/Left-Tags), built in, with its own **Left Tags** tab: runs of the same tag collapse into one with a count, and **F6** turns that off and on. Installing Left Tags as well is fine.

It doesn't need Steamodded, and works next to [Ankh](https://github.com/MathIsFun0/Ankh). With [andy-balatro's Saturn](https://github.com/andy-balatro/Saturn), Saturn's shortcut indicators sit just above the chat.

## Install

1. Install Lovely: download `lovely-x86_64-pc-windows-msvc.zip` from the [Lovely releases](https://github.com/ethangreen-dev/lovely-injector/releases) and copy `version.dll` into the Balatro game folder (Steam → Balatro → Manage → Browse local files). Skip this if you already use Ankh or other mods.
2. Download this mod (Code → Download ZIP) and unzip it into `%AppData%\Balatro\Mods`, so there's a folder in there with `lovely.toml` directly inside. The folder's name doesn't matter.
3. Start the game, open Options → Settings → **Chat** and type your Twitch name. Or link the game (below), and it shows your chat without typing anything.

## Channel point redemptions

Twitch doesn't show anonymous chat the redemptions without a message, or any reward's name. [bot.andy-balatro.com](https://bot.andy-balatro.com) passes them on:

1. Sign in with Twitch at [bot.andy-balatro.com](https://bot.andy-balatro.com) and press **Show redemptions**. Twitch asks you to let the bot see them.
2. In the game, open Options → Settings → **Chat** and press **Link**. A code shows up.
3. Press **Open the page** in the game to get there with the code filled in, or **Copy code** and paste it on the site.

The game says `Linked to <you>` and shows redemptions as they happen. The same link works for the [Progress Tracker](https://github.com/andy-balatro/progress-tracker), if you use it too. Stop showing them, or unlink the game, on the site.

## Files

- `chat.lua`: reading chat, emotes, and drawing the panel.
- `settings.lua`: the Chat tab and the shortcuts.
- `andys_link.lua`: linking the game. Progress Tracker has the same file, and only one copy runs.
- `left-tags/`: a copy of Left Tags.

`lovely.toml` appends them to the game's `main.lua`. Each is wrapped in a block, so they share only the `AndysChat`, `AndysLink` and `LeftTags` globals. Chat and emotes load on background threads, so a slow or dead connection never stalls the game.

The settings (channel, height and shortcuts) are saved in `config/andys-chat.jkr` in the game's save folder, and the link in `config/andys-link.jkr`. Set the `ANDYS_MODS_URL` environment variable to point the link at another server (e.g. `http://localhost:3000` while working on the bot). Errors go to `Mods\lovely\log`.

When changing `andys_link.lua` or `left-tags/`, copy the change to Progress Tracker or Left Tags as well. Whichever copy loads first is the one that runs.

## Development

Link the repo into the mods folder so edits apply on the next game launch (PowerShell, from this repo):

```powershell
New-Item -ItemType Junction -Path "$env:APPDATA\Balatro\Mods\andys-chat" -Target "$PWD"
```

To check what got injected, look at `%AppData%\Balatro\Mods\lovely\dump\main.lua`.
