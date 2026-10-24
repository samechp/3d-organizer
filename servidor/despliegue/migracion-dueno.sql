-- migracion-dueno.sql - Cada cuenta ve solo lo suyo (MariaDB 10.11, base 'sistema').
--
-- Agrega la columna dueno a pedidos, perfiles y filamentos, y le asigna a Juan
-- todo lo que ya existe. Modelos y tandas no cambian: cuelgan de su pedido.
-- Se puede repetir sin romper nada (IF NOT EXISTS / IF EXISTS en cada paso).
--
-- Uso (ver montar.md, "Migracion: un dueno por renglon"): cambiar el correo de
-- abajo y correr  sudo mariadb sistema < migracion-dueno.sql

SET @dueno = 'PON_AQUI_EL_CORREO';

-- Si se olvido poner el correo, se corta aqui: si no, todo quedaria a nombre
-- de un correo que no existe y Juan dejaria de ver sus datos.
DELIMITER //
BEGIN NOT ATOMIC
  IF @dueno NOT LIKE '%_@_%._%' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Falta poner el correo en @dueno';
  END IF;
END//
DELIMITER ;

-- Primero nullable, luego se llena y solo entonces NOT NULL: los renglones
-- viejos no tienen dueno y el ALTER fallaria.
ALTER TABLE pedidos ADD COLUMN IF NOT EXISTS dueno VARCHAR(120) NULL;
ALTER TABLE perfiles ADD COLUMN IF NOT EXISTS dueno VARCHAR(120) NULL;
ALTER TABLE filamentos ADD COLUMN IF NOT EXISTS dueno VARCHAR(120) NULL;

UPDATE pedidos SET dueno = @dueno WHERE dueno IS NULL;
UPDATE perfiles SET dueno = @dueno WHERE dueno IS NULL;
UPDATE filamentos SET dueno = @dueno WHERE dueno IS NULL;

ALTER TABLE pedidos MODIFY dueno VARCHAR(120) NOT NULL;
ALTER TABLE perfiles MODIFY dueno VARCHAR(120) NOT NULL;
ALTER TABLE filamentos MODIFY dueno VARCHAR(120) NOT NULL;

-- Mismos nombres que en base.py.
CREATE INDEX IF NOT EXISTS ix_pedidos_dueno ON pedidos (dueno);
CREATE INDEX IF NOT EXISTS ix_perfiles_dueno ON perfiles (dueno);
CREATE INDEX IF NOT EXISTS ix_filamentos_dueno ON filamentos (dueno);

-- El nombre del perfil deja de ser unico en toda la tabla y pasa a serlo por
-- cuenta. MariaDB llamo 'nombre' al indice del UNIQUE de columna.
DROP INDEX IF EXISTS nombre ON perfiles;
CREATE UNIQUE INDEX IF NOT EXISTS ux_perfiles_dueno_nombre ON perfiles (dueno, nombre);

-- Comprobacion: ningun renglon sin dueno y los indices en su sitio.
SELECT 'pedidos sin dueno' AS que, COUNT(*) AS cuantos FROM pedidos WHERE dueno IS NULL OR dueno = ''
UNION ALL SELECT 'perfiles sin dueno', COUNT(*) FROM perfiles WHERE dueno IS NULL OR dueno = ''
UNION ALL SELECT 'filamentos sin dueno', COUNT(*) FROM filamentos WHERE dueno IS NULL OR dueno = '';
SHOW INDEX FROM perfiles;
