# Guia de Contribucion - Ghost-Kali v5.0

**Version:** 5.0.0 | **Fecha:** 2026-06-24

---

## 1. Bienvenida

Ghost-Kali es un toolkit defensivo de anonimato para Kali Linux, orientado a
la educacion en privacidad y a las auditorias de seguridad autorizadas. Las
contribuciones son bienvenidas.

Tipos de contribucion valorados:

- Codigo (nuevas funciones, correcciones, refactorizaciones).
- Documentacion.
- Tests (BATS).
- Reportes de bugs.
- Sugerencias de features.
- Auditorias de seguridad y revisiones de codigo.

## 2. Requisitos de Codigo

Todo codigo debe cumplir, sin excepcion:

- `shellcheck -S error`: 0 errores.
- `shfmt -i 4 -ci`: sin diferencias.
- Tests BATS para cada funcion nueva.
- Comentarios en espanol; nombres de variables y funciones en ingles.
- Respetar los prefijos de modulo: `proxyctl_`, `torctl_`, `vpnctl_`.
- Ninguna funcion destructiva sin `--dry-run`.
- Sin dependencias exoticas: limitarse a utilidades estandar de Kali.

Antes de abrir un PR:

```bash
shellcheck -S error lib/*.sh joseph-trio install.sh uninstall.sh
shfmt -i 4 -ci -d lib/*.sh joseph-trio install.sh uninstall.sh
bats tests/
```

## 3. Flujo de Trabajo con Git

1. Hacer fork del repositorio.
2. Crear una rama: `feat/nombre-descriptivo` o `fix/nombre-descriptivo`.
3. Commits atomicos con mensajes claros (que cambia y por que).
4. Rebase sobre `main` antes de abrir el PR.
5. Abrir el PR con una descripcion completa: que, por que y como probarlo.

## 4. Como Reportar Bugs

- Usar GitHub Issues.
- Incluir: version del toolkit, version de Kali, pasos para reproducir,
  comportamiento esperado, comportamiento observado y logs relevantes.
- No incluir datos sensibles, IPs reales ni credenciales.

## 5. Como Proponer Features

- Abrir un Issue con el prefijo `[FEATURE]`.
- Describir el problema que resuelve la propuesta.
- Esbozar una posible implementacion.
- Discutir el diseno antes de escribir codigo.

## 6. Proceso de Pull Request

- El pipeline de CI debe pasar (`lint-shell`, `test-bats`, `validate-structure`).
- Revision de al menos un maintainer.
- No se mergea sin aprobacion.
- Squash merge a `main`.

## 7. Codigo de Conducta

Toda participacion se rige por el `CODE_OF_CONDUCT.md`. En resumen: respeto
mutuo, critica constructiva y un entorno profesional. Las violaciones se
gestionan segun lo descrito en ese documento.

## 8. Licencia

El proyecto se distribuye bajo licencia MIT. Toda contribucion se entiende
aportada bajo la misma licencia.
