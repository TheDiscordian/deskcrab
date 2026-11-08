# Image fetch recipes

Named by the IMAGES line of the identity layer (`build_system_prompt`, L1). The embed rule and
the thumbnail rule stay in the prompt; these are the fetch recipes, one open away — they were
measured riding on every turn while being needed a few times a day.

## One picture of a known topic — Wikipedia

```
curl -s 'https://en.wikipedia.org/api/rest_v1/page/summary/TOPIC'
```

Take `.originalimage.source`.

## Several at once — Wikimedia Commons search

```
curl -s 'https://commons.wikimedia.org/w/api.php?action=query&generator=search&gsrsearch=TOPIC&gsrnamespace=6&prop=imageinfo&iiprop=url&format=json'
```

Take each page's full-size `url`. **Never a thumbnail url** — they are blocked and return a web
page instead of an image.

## Fetch and verify, always

```
curl -sL -A 'Mozilla/5.0' -o /tmp/x.jpg '<url>'
file /tmp/x.jpg
```

Only show the file if `file` says JPEG or PNG. Anything else is an error page wearing an image
name, and embedding it shows a broken square.
