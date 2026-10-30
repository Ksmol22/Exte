# Revisor SQL — Agente para Microsoft 365 Copilot

## Contenido del paquete

| Archivo | Uso |
|---|---|
| `instrucciones-agente.txt` | Instrucciones del agente (5 863 caracteres; el límite es 8 000). |
| `conocimiento-validacion-sql.md` | Catálogo de reglas, plantillas por motor y matriz de riesgo. Se carga como conocimiento. |
| `declarativeAgent.json` | Manifiesto para Microsoft 365 Agents Toolkit (opción B). |
| `casos-de-prueba.md` | 10 scripts con el dictamen esperado para validar el agente. |

## Opción A — Copilot Studio / Agent Builder (sin código)

1. En Microsoft 365 Copilot, abre **Crear agente** (o Copilot Studio → Nuevo agente).
2. Ve a la pestaña **Configurar**.
3. **Nombre:** `Revisor SQL`. **Descripción:** copia la de `declarativeAgent.json`.
4. **Instrucciones:** pega todo el contenido de `instrucciones-agente.txt`.
5. **Conocimiento:** sube `conocimiento-validacion-sql.md` o enlaza la carpeta de SharePoint donde lo guardes. Si tu tenant no acepta `.md`, guárdalo como `.docx` o `.pdf`.
6. Desactiva la búsqueda web: el agente no la necesita y evita respuestas con fuentes externas.
7. Agrega los 4 iniciadores de conversación del manifiesto.
8. Prueba con `casos-de-prueba.md` y publica.

## Opción B — Microsoft 365 Agents Toolkit (VS Code)

1. Crea un proyecto **Declarative Agent** en Agents Toolkit.
2. Reemplaza `appPackage/declarativeAgent.json` por el de este paquete.
3. Copia `instrucciones-agente.txt` en `appPackage/` (el manifiesto lo referencia con `$[file('instrucciones-agente.txt')]`).
4. Sube `conocimiento-validacion-sql.md` a SharePoint y reemplaza la URL de ejemplo en `items_by_url`.
5. Ajusta `name` y `description` también en `manifest.json` del paquete de la app.
6. **Provision** → prueba en Copilot con los casos de prueba.

> Si tu versión del Toolkit usa una versión de esquema más reciente, actualiza `$schema` y `version`; los campos usados aquí se mantienen.

## Personalización recomendada

- **Motor principal:** si tu organización usa solo un motor, cambia en las instrucciones "Si es ambiguo, asume SQL Server" por tu motor.
- **Umbral de volumen:** el agravante usa 100 000 filas; ajústalo a tu realidad.
- **Reglas propias:** agrega filas al catálogo con un nuevo ID (p. ej. `ORG-01: prohibido usar la tabla X sin el filtro Y`).
- **Aprobadores:** reemplaza "DBA/responsable" por el rol o equipo real de tu área.

## Límites a tener presentes

- El análisis es estático: el agente no conoce el esquema real, índices ni volúmenes, salvo que se los indiques.
- No sustituye la revisión de un DBA en cambios críticos; está pensado como primer filtro.
