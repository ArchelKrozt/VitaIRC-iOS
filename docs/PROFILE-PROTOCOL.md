# VitaIRC profiles over IRC (VPROFILE)

Profiles go from app to app over IRC itself, with CTCP messages: no server of our own. VitaIRC for
PS Vita, Android and iPhone all speak it. A profile can be seen only while its owner's app is
connected.

## Request

```
PRIVMSG <nick> :\x01VPROFILE\x01
```

## Answer

NOTICEs to the requester, one field per line, each `\x01VPROFILE <TYPE> <data>\x01`:

| Line | Data |
|---|---|
| `BEGIN 1` | protocol version |
| `NAME <text>` | display name, up to 40 characters |
| `BIO <chunk>` | bio (up to 280 characters), cut into chunks of at most 200 bytes at character boundaries; the receiver joins them in order |
| `AVATAR <base64>` | JPEG of 64×64 px, base64 in chunks of 300 characters; joined in order |
| `FAV <engine> <id> <thumb>` | a public favorite (up to 12): engine 0 Safebooru, 1 Danbooru, 2 Sankaku; `<thumb>` is the thumbnail URL, or `-` (Sankaku's expire: the viewer looks the post up again) |
| `END` | end of the profile |

When the owner doesn't share a profile, the whole answer is one line: `VPROFILE NONE`.

## Rules

- An app answers the same nick at most once every 30 s, never answers ignored nicks and never answers
  requests replayed from history (chathistory batches).
- Answers are paced: after the first 3 lines, one line every 800 ms (IRC servers disconnect clients
  that send too fast). A full profile takes about 10 to 15 s.
- The receiver keeps lines from that nick between `BEGIN` and `END` for at most 60 s, and gives up
  after 25 s without `BEGIN` ("doesn't use VitaIRC or isn't connected").
- `VPROFILE` lines are never shown as notices.
- Private favorites never leave the device; only the ones marked public are sent.

## Files on the device

- `profile.txt`: `name=`, `bio=` (newlines written as `\n`), `share=1|0`
- `profile_avatar.jpg`: the 64×64 avatar that is sent (apps may also keep a bigger copy for themselves)
- `profile_favs.txt`: one public favorite per line, `<engine>/<id>`

## Related: author of a search result

`favorites.txt` gets a 12th field, the artist (Danbooru's `tag_string_artist`, Sankaku's tags of type
artist; Safebooru gives none). An image sent from the search goes as `<url> 🎨 <artist>`; VitaIRC shows
the `🎨 <artist>` part under the image preview.
