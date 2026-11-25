# Superbrief: Chebit (nombre tentativo)

Brief de arranque para que Claude Fable 5.2 orqueste la implementación. Autor del producto: Julián. Fecha: 20 de noviembre de 2026.

Este archivo es el brief original, sin cambios. El plan vive en `docs/PLAN.md` y las decisiones en `docs/adr/`.

## 1. Rol del orquestador

Sos el orquestador técnico del proyecto. Tu trabajo es:

1. Convertir este brief en un plan de implementación por fases, con workstreams paralelizables.
2. Definir primero los contratos (interfaces, modelo de datos, state machine) y recién después repartir trabajo.
3. Proteger las invariantes del sistema con tests en cada fase.
4. Registrar cada decisión importante como ADR (Architecture Decision Record).
5. Cuando algo no esté definido acá, proponer una opción por defecto razonable y anotarla en "Preguntas abiertas", en vez de frenar.

Principio rector: KISS. Simple y correcto primero; escalar cuando se mida.

## 2. Visión del producto

Una pasarela de pagos argentina que une pesos, dólares y Bitcoin en un solo contrato, con el objetivo de favorecer la adopción de Bitcoin.

- Para las personas: pagar en cualquier comercio con lo que tengan (Mercado Pago, transferencia, tarjeta, Lightning, stablecoins).
- Para los comercios: un punto de venta y gestión del negocio (empezando por gastronomía) con facturación electrónica en ARCA, todo regularizado, que además les permite aceptar Bitcoin y recibir en pesos si quieren.
- Diferencial: unir rieles locales, Lightning y stablecoins bajo una sola API, con una API pública y un servidor MCP para que lo usen agentes de IA.

Primeros clientes reales: los propios negocios de Julián (RenovaFácil y su importadora) y 3 o 4 restaurantes piloto.

## 3. Alcance por fases

### Fase 0: Fundaciones (núcleo de pagos)

- Ledger de doble entrada, append-only, en Postgres.
- Idempotencia en todos los endpoints de escritura.
- State machine común de pagos.
- Holds (reservas de saldo).
- Outbox pattern para eventos.
- Inbox de webhooks con deduplicación.
- Interfaz común de proveedor (patrón adapter) con un proveedor simulado para tests.

### Fase 1: MVP comercio piloto

- QR universal: un solo QR que se paga con Mercado Pago, Transferencias 3.0 o Lightning.
- Liquidación al comercio en pesos aunque el cliente pague en Bitcoin (conversión vía partner).
- Factura electrónica automática en ARCA por cada venta.
- Panel de conciliación: todo lo cobrado en todos los medios, cuadrado contra el ledger.

### Fase 2: Más proveedores

MODO, Ualá, Payway (ex Decidir/Prisma), Fiserv, Stripe (verificar disponibilidad y modalidad para cuentas argentinas), dLocal, EBANX, USDT y USDC, y exchanges locales como puente cripto a pesos (Lemon, Ripio, Belo).

### Fase 3: Adopción de Bitcoin (lado usuario)

- Vuelto en sats: un porcentaje de cada compra vuelve al usuario en satoshis.
- Redondeo: cada pago se redondea y la diferencia se ahorra en Bitcoin.
- Mapa de comercios que aceptan Bitcoin (integrar o alimentar BTC Map).
- Educación gamificada con misiones y premios en sats.
- Autocustodia fácil: retirar sats a una wallet propia.
- Comunidad, promos con partners, loyalty y gamificación.

### Fase 4: Gestión completa del comercio y plataforma

Stock, mesas, reservas, multi-sucursal. API pública documentada, SDKs y servidor MCP. Enrutamiento inteligente entre proveedores (por costo, tasa de aprobación y disponibilidad).

### Fuera de alcance por ahora (ideas aparcadas)

Marketplace, scraping de promociones según gustos, sourcing desde China, alquileres entre personas, subastas u opciones, integración con MSTR y STRC (Stretch), y operar como banco. No implementar sin una decisión explícita de Julián.

## 4. Arquitectura

### Lenguajes

- Elixir (Phoenix) para el núcleo de orquestación: cada pago es un proceso liviano con su state machine, supervisado (si falla, se reinicia sin afectar al resto). Encaja con un sistema que pasa la mayor parte del tiempo esperando a proveedores, webhooks y pagos en vuelo.
- Rust solo donde aporta: el servicio de Lightning (LDK está escrito en Rust) y el servicio de firma y custodia de claves.
- Evaluar en un ADR si conviene arrancar Lightning con un proveedor gestionado (LSP o SDK hosteado) para no operar un nodo propio en el MVP.

### Componentes

1. API Gateway: autenticación, rate limiting, idempotency keys.
2. Payments service (Elixir): payment intents, state machine, enrutamiento a proveedores.
3. Provider adapters: uno por proveedor, todos detrás de la misma interfaz.
4. Ledger service: único componente que escribe asientos.
5. Quote/FX service: cotizaciones con vencimiento (BTC, USDT, ARS, USD).
6. Webhook inbox: recibe, guarda en crudo, deduplica y procesa eventos de proveedores.
7. Outbox publisher: publica eventos internos de forma confiable.
8. Reconciliation jobs: cuadran el ledger contra cada proveedor, el banco y la blockchain.
9. Invoicing service: facturación electrónica en ARCA (web service de factura electrónica, certificado digital, CAE).
10. Lightning service (Rust): envío y recepción, estados de pagos en vuelo.
11. Signing/custody service (Rust): claves en HSM o KMS, hot wallet con límites, cold storage para el resto.
12. Merchant app y dashboard: POS, QR, conciliación, facturas.

### Infraestructura inicial

Postgres como fuente de verdad. Colas y jobs sobre Postgres (por ejemplo Oban) en vez de Kafka al principio. Redis solo como caché o rate limiting, nunca como fuente de verdad.

## 5. Invariantes (no negociables)

1. Cada transacción del ledger suma cero, por moneda: débitos igual a créditos.
2. El ledger es append-only: nunca se edita ni se borra un asiento; las correcciones son asientos de reverso.
3. El saldo disponible (contable menos holds) nunca es negativo.
4. Un mismo request con la misma idempotency key tiene efecto una sola vez; los reintentos devuelven la respuesta original.
5. Un pago o retiro se envía al proveedor o a la blockchain exactamente una vez en efecto.
6. Los estados finales de la state machine son inmutables; las transiciones solo van hacia adelante.
7. Nunca se usan floats para dinero: enteros en unidad mínima (centavos, satoshis, unidad mínima de cada stablecoin).
8. Los fondos reales en custodia son siempre mayores o iguales a lo que el ledger les debe a los usuarios.
9. Toda venta cobrada a un comercio tiene su factura en ARCA o queda marcada como pendiente de facturar.

Cada invariante necesita tests, idealmente property-based (StreamData en Elixir), y chequeos periódicos en producción.

## 6. Modelo de datos (entidades núcleo)

- accounts: una cuenta por moneda y por titular (usuario, comercio o cuenta de la casa). Subcuentas de la casa por shard si en el futuro se particiona.
- ledger_transactions: agrupa asientos, con referencia al pago u operación de origen. Constraint única por operación de origen.
- postings (entries): cuenta, monto, moneda, débito o crédito.
- holds: reservas de saldo vinculadas a un pago, con estado (activo, capturado, liberado).
- payment_intents: el pago desde la perspectiva del negocio: monto, moneda, comercio, estado, failure_reason.
- payment_attempts: cada intento contra un proveedor concreto, con su ID externo.
- provider_events: inbox de webhooks en crudo, únicos por proveedor e ID de evento.
- idempotency_keys: key, hash del body, respuesta guardada, estado.
- outbox_events: eventos pendientes de publicar.
- merchants, invoices (ARCA), settlements, fx_quotes.
- Para Bitcoin on-chain: withdrawals, batches (transacción con txid y fee) y utxos (libre, reservado, gastado).

El balance se deriva de los asientos y se puede cachear; no es la fuente de verdad.

## 7. State machine común de pagos

Estados: creado → pendiente → pagado → final, más los de cierre fallido, expirado, reembolsado y en disputa (contracargo).

- Pagado: el proveedor aceptó el pago, pero todavía se puede revertir.
- Final: ya no hay vuelta atrás.
- El detalle del error va en un campo failure_reason con código, no en estados nuevos.

Mapeo esperado por tipo de proveedor (a confirmar contra la documentación de cada uno):

- Lightning y Transferencias 3.0: pagado y final ocurren casi juntos (son finales e irrevocables).
- Tarjetas (Payway, Fiserv, Stripe, Mercado Pago con tarjeta): pagado al aprobarse; final recién cuando vence la ventana de contracargo.
- On-chain (BTC, USDT, USDC): pagado al verse la transacción; final tras N confirmaciones (N configurable por monto y red).

Reglas de producto por medio de pago (ejemplos de Julián): Lightning sin reembolso automático; P2P con arbitraje de la plataforma y límite de tiempo.

## 8. Patrones obligatorios

- Idempotencia: key en el header. Mismo body: devolver la respuesta guardada. Mismo key con body distinto o request en proceso: 409.
- Payment intents: el server crea el intent y devuelve un ID; el cliente confirma sobre ese ID. Los reintentos reusan el mismo intent.
- Holds: reservar saldo de forma atómica (update condicional) antes de devolver 202 en flujos asincrónicos.
- Outbox: el evento se escribe en la misma transacción que los asientos; un proceso aparte lo publica. Entrega at-least-once, consumidores idempotentes.
- Webhook inbox: guardar crudo, deduplicar por ID de evento, tolerar desorden consultando el estado actual al proveedor.
- Sagas: para operaciones entre sistemas (por ejemplo cobro en BTC y liquidación en ARS), con saga log, pasos idempotentes (saga ID + número de paso) y asientos de compensación.
- Bitcoin on-chain: batching de retiros; guardar la transacción firmada, su txid y sus UTXOs antes de transmitirla; ante una caída, retransmitir la misma, nunca armar otra. RBF para acelerar transacciones trabadas.
- Concurrencia: lock de fila (select for update) o update condicional al tocar saldos.

## 9. Regulatorio (a validar con los abogados de Julián)

No es asesoramiento legal; son puntos a confirmar:

- Si solo se provee software y los fondos pasan por proveedores regulados: en principio, proveedor de tecnología.
- Si se custodian fondos de clientes en cuentas: registro como Proveedor de Servicios de Pago (PSP) ante el BCRA.
- Si se custodia o convierte cripto: inscripción como PSAV ante la CNV.
- Prevención de lavado: oficial de cumplimiento, KYC y reportes a la UIF.
- Contrato con cada comercio: comisiones, plazos de acreditación y riesgo de tipo de cambio.

Diseñar el sistema para que la Fase 1 pueda operar en el escalón regulatorio más bajo posible.

## 10. Plan de orquestación sugerido

1. Contratos primero: esquema de base, interfaz de proveedor, state machine y API pública (OpenAPI). ADRs de lenguaje, colas y Lightning.
2. Workstream A, Ledger: postings, holds, invariantes y tests property-based.
3. Workstream B, Payments core: intents, idempotencia, state machine, outbox, inbox.
4. Workstream C, Adapters: proveedor simulado primero; después Mercado Pago, Transferencias 3.0 y Lightning.
5. Workstream D, ARCA: facturación electrónica en homologación.
6. Workstream E, Merchant app: QR universal y panel de conciliación.
7. Integración end-to-end con un restaurante simulado: venta en Lightning, liquidación en pesos, factura emitida, ledger cuadrado.

### Definition of done de cada entrega

Tests de invariantes pasando, idempotencia probada con reintentos, conciliación cuadrando a cero, y un README de cómo correrlo con un solo comando.

## 11. Preguntas abiertas para Julián

1. Nombre definitivo: Chebit es el candidato principal (no se encontró una app con ese nombre); falta verificar en el INPI y los dominios.
2. ¿Custodia propia de Bitcoin en la Fase 1 o solo vía partner?
3. Partner para convertir BTC y stablecoins a pesos.
4. ¿Quién asume el riesgo de tipo de cambio entre el cobro y la liquidación?
5. Comisiones al comercio y modelo de negocio.
6. Restaurantes piloto concretos.
7. Hosting e infraestructura preferidos.
