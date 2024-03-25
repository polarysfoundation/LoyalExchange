Reporte de Auditoría de Seguridad

Resumen

El contrato LoyalProtocol implementa un mercado para el intercambio de NFTs y otros activos digitales. Permite a los usuarios crear y completar órdenes de compra/venta, hacer ofertas y realizar subastas. El contrato administra el depósito en garantía (escrow) y la transferencia de activos entre las partes.

Funciones clave

createBasicOrder - Crea una nueva orden de compra/venta.
fillBasicOrder - Completa una orden existente de compra/venta.
cancelBasicOrder - Cancela una orden sin completar.
makeOffer - Realiza una oferta por un activo.
acceptOffer - Acepta una oferta existente.
cancelOffer - Cancela una oferta.
createAuction - Crea una nueva subasta.
bid - Coloca una puja en una subasta.
cancelAuction - Cancela una subasta activa.
claimAuction - El postor ganador reclama el NFT después de que finaliza la subasta.
El contrato utiliza ReentrancyGuard de OpenZeppelin para prevenir ataques de reentrada.

Análisis de Vulnerabilidades

Desbordamiento de Enteros (Integer Overflow)

Gravedad: Alta
ID SWC: SWC-101
Las funciones _safeAdd y _safeSub de la librería SafeMath se utilizan en varios lugares para prevenir el overflow/underflow de enteros. Esto mitiga el riesgo.

Control de Acceso y Autorización

Gravedad: Media
ID SWC: SWC-999
El modificador onlyAdmin restringe el acceso a funciones sensibles como la actualización de los parámetros del protocolo y la dirección administrativa. Es una buena práctica.

Sin embargo, no hay controles de acceso en torno a la creación y cancelación de órdenes.  Cualquier usuario puede crear y cancelar órdenes en nombre de otros usuarios, lo que puede conducir a potenciales ataques de abuso o sabotaje.

Recomendación: Agregar modificadores para asegurar que solo el creador de la orden pueda cancelarla.
Reentrada (Reentrancy)

Gravedad: Media
ID SWC: SWC-107
El uso de ReentrancyGuard previene ataques de reentrada al completar órdenes o transferir activos.

Sin embargo, hay que evitar las llamadas externas a los contratos royaltyVault y transferHelper en estados intermedios en donde las variables de estado hayan sido actualizadas pero los activos no hayan sido transferidos aún. Esto puede llevar a una vulnerabilidad de reentrada.

Recomendación:
Mover todas las llamadas externas al final, después de actualizar el estado interno.
Considerar utilizar el patrón de "cheques-efectos-interacciones" (checks-effects-interactions).
Errores de Lógica

Gravedad: Media
No existe validación para garantizar que el firmante de la orden sea realmente el propietario del activo.  Esto podría permitir que cualquiera cree órdenes falsas en nombre de un usuario.

Recomendación: Validar que el firmante de la orden es el dueño del activo antes de crearla.
Llamadas Externas

Gravedad: Baja
El contrato realiza llamadas externas a royaltyVault y transferHelper. Hay que asegurarse de que existen las validaciones adecuadas para evitar ataques como la reentrada. Verificar la titularidad del contrato, implementar mecanismos de retroceso (rollbacks), etc.

Resumen

En general, el contrato implementa un mercado NFT básico con algunas protecciones de control de acceso y reentrada. Existen algunos puntos preocupantes en torno a la validación adecuada de autorizaciones y el orden de las operaciones. Seguir las mejores prácticas en torno al patrón “cheques-efectos-interacciones” puede hacer el código más robusto.