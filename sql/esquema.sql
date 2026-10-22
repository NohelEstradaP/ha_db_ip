-- Se ejecuta UNA vez, conectado a la BD hadb como usuario app, en el primario.

CREATE TABLE cuentas (
    id          integer       PRIMARY KEY,
    titular     text          NOT NULL,
    saldo       numeric(14,2) NOT NULL CHECK (saldo >= 0),
    actualizado timestamptz   NOT NULL DEFAULT now()
);

CREATE TABLE movimientos (
    id         bigserial     PRIMARY KEY,
    generador  text          NOT NULL,          -- p.ej. "n2-20261105101500"
    seq        bigint        NOT NULL,          -- 1, 2, 3, ... sin huecos por generador
    origen     integer       NOT NULL REFERENCES cuentas(id),
    destino    integer       NOT NULL REFERENCES cuentas(id),
    monto      numeric(14,2) NOT NULL CHECK (monto >= 0),
    primario   text          NOT NULL,          -- IP del primario que aceptó la escritura
    creado     timestamptz   NOT NULL DEFAULT now(),
    CONSTRAINT movimientos_generador_seq_uk UNIQUE (generador, seq)
);

CREATE INDEX movimientos_creado_idx ON movimientos (creado);

-- 100 cuentas con Q10,000.00 cada una -> la suma total SIEMPRE debe ser 1,000,000.00
INSERT INTO cuentas (id, titular, saldo)
SELECT g, 'Cuenta ' || g, 10000
FROM generate_series(1, 100) AS g;
