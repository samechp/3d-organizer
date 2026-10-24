-- migracion-productos-id-cliente.sql - id_cliente en productos (MariaDB 10.11, base 'sistema').
--
-- La tabla productos ya existe en produccion, y create_all no agrega columnas
-- a tablas que ya estan: esto agrega la columna y su indice unico (el mismo
-- nombre que en servidor/app/base.py). Los productos que ya existen quedan con
-- NULL, que el indice unico admite repetido. Se puede repetir sin romper nada.
--
-- Uso: sudo mariadb sistema < migracion-productos-id-cliente.sql

ALTER TABLE productos ADD COLUMN IF NOT EXISTS id_cliente CHAR(36) NULL;
CREATE UNIQUE INDEX IF NOT EXISTS ux_productos_id_cliente ON productos (id_cliente);
