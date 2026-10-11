# Changelog

## 1.2

- **Quoted replies**: swipe a message to the right (or Reply in its menu); replies go out as IRCv3
  `+draft/reply` and show the quoted message, which takes you to the original when tapped.
- **Image authors**: images sent from the image search carry their artist and it shows under the
  picture in the chat.
- **User card**: tapping a user opens a floating card with their VitaIRC profile and the WHOIS
  answer.
- **VitaIRC profiles**: name, bio, picture and public favorites, kept on the device and sent over
  IRC to whoever asks (no external server; see [docs/PROFILE-PROTOCOL.md](docs/PROFILE-PROTOCOL.md)).
  Works between Android, iPhone and PS Vita.
- **Floating video player**: videos from the chat play in a small window you can keep open while
  chatting; Imgur GIFs (MP4) play inline, muted and looping.

## 1.1

- Leaving the app: the extra background time iOS gives (about 30 s) is now requested with the
  system's own signal, so short trips to another app don't drop the connection.
- Back in the app: the connection is checked in 5 s instead of 15, and a dead or waiting one
  reconnects at once (with a bouncer, what was said meanwhile comes back with its real time).
- The server window says what happened: background time given, app suspended, why a connection
  ended (iOS closed it, no network...).

## 1.0

First version of VitaIRC for iPhone and iPad, with the features of VitaIRC 1.4 for PS Vita and
VitaIRC 1.0 for Android:

- Several servers, SSL/TLS, SASL / NickServ / server password, reconnection, flood protection.
- Bouncers: IRCv3 chat history (missed messages with their real time, older ones on scroll),
  reactions, soju FILEHOST uploads.
- Translation with Google or ChatGPT (incoming, outgoing, one message, language per channel).
- Image uploads (Litterbox, ImgBB, Imgur, soju) from Photos or the camera.
- Link previews (animated GIFs too), video player, image viewer with zoom, save to Photos.
- Image search (Safebooru, Danbooru, Sankaku) with favorites.
- Channel browser with search, user list with operator actions, quick replies, nick completion,
  search in a channel, mute, ignore, highlight words, notifications.
- iPad and landscape: window list and chat side by side. Settings in the Files app (config.ini).
