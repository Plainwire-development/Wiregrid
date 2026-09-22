import Config

# Keep credentials in the embedding application's runtime configuration or
# secret manager. Wiregrid accepts caller-owned database/cache connections at
# instance startup; it does not read credentials or phone home by itself.
