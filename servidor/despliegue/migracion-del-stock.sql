-- migracion-del-stock.sql - Modelos "del stock" (MariaDB 10.11, base 'sistema').
--
-- modelos y movimientos ya existen en produccion, y create_all no agrega
-- columnas a tablas que ya estan: esto agrega las dos columnas, sus indices y
-- sus llaves foraneas con los mismos nombres que en servidor/app/base.py. Lo que
-- ya existe queda en NULL (modelos de siempre, ventas sueltas), que el indice
-- unico admite repetido. Se puede repetir sin romper nada.
--
-- Uso: sudo mariadb sistema < migracion-del-stock.sql

ALTER TABLE modelos ADD COLUMN IF NOT EXISTS opcion_id INT NULL;
CREATE INDEX IF NOT EXISTS ix_modelos_opcion ON modelos (opcion_id);
ALTER TABLE modelos ADD CONSTRAINT fk_modelos_opcion
    FOREIGN KEY IF NOT EXISTS (opcion_id) REFERENCES opciones (id);

ALTER TABLE movimientos ADD COLUMN IF NOT EXISTS modelo_id INT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS ux_movimientos_modelo ON movimientos (modelo_id);
ALTER TABLE movimientos ADD CONSTRAINT fk_movimientos_modelo
    FOREIGN KEY IF NOT EXISTS (modelo_id) REFERENCES modelos (id);
