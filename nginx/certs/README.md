# SSL-сертификаты для gateway (режим HTTPS)

Положите сюда файлы от удостоверяющего центра (имена **фиксированные**):

| Файл | Содержимое |
|------|------------|
| `fullchain.pem` | сертификат сайта + промежуточные (chain) |
| `privkey.pem` | приватный ключ |

Права на сервере:

```bash
chmod 640 privkey.pem
chown root:root fullchain.pem privkey.pem
```

Активация HTTPS:

```bash
cd /path/to/etp/deploy
./scripts/switch-tls.sh https
```

Не коммитьте сертификаты в git.
