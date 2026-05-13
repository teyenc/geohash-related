-- Pure-SQL geohash helpers extracted from Dan's yb_geospatial extension.
-- These are plain functions (not an extension) so they coexist with
-- yb_geospatial_s2 in lat_bench without the geometry-type conflict.

-- ------- geohash_encode (extracted) -------
CREATE OR REPLACE FUNCTION geohash_encode(
   p_lat double precision,
   p_lon double precision,
   p_precision integer DEFAULT 10
)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
   base32 constant text := '0123456789bcdefghjkmnpqrstuvwxyz';
   lat_min double precision := -90.0;
   lat_max double precision :=  90.0;
   lon_min double precision := -180.0;
   lon_max double precision :=  180.0;
   is_even boolean := true;
   bit integer := 0;
   ch integer := 0;
   mid double precision;
   geoh text := '';
BEGIN
   IF p_precision IS NULL OR p_precision < 1 THEN
      RAISE EXCEPTION 'geohash_encode: precision must be >= 1';
   END IF;
   WHILE char_length(geoh) < p_precision LOOP
      IF is_even THEN
         mid := (lon_min + lon_max) / 2.0;
         IF p_lon >= mid THEN ch := (ch * 2) + 1; lon_min := mid;
         ELSE ch := (ch * 2); lon_max := mid; END IF;
      ELSE
         mid := (lat_min + lat_max) / 2.0;
         IF p_lat >= mid THEN ch := (ch * 2) + 1; lat_min := mid;
         ELSE ch := (ch * 2); lat_max := mid; END IF;
      END IF;
      is_even := NOT is_even;
      bit := bit + 1;
      IF bit = 5 THEN
         geoh := geoh || substr(base32, ch + 1, 1);
         bit := 0; ch := 0;
      END IF;
   END LOOP;
   RETURN geoh;
END;
$$;

-- ------- geohash_adjacent (extracted) -------
CREATE OR REPLACE FUNCTION geohash_adjacent(
   p_hash text,
   p_dir  text
)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
   base32 constant text := '0123456789bcdefghjkmnpqrstuvwxyz';
   neighbor_n constant text := 'p0r21436x8zb9dcf5h7kjnmqesgutwvy';
   neighbor_s constant text := '14365h7k9dcfesgujnmqp0r2twvyx8zb';
   neighbor_e constant text := 'bc01fg45238967deuvhjyznpkmstqrwx';
   neighbor_w constant text := '238967debc01fg45kmstqrwxuvhjyznp';
   border_n  constant text := 'prxz';
   border_s  constant text := '028b';
   border_e  constant text := 'bcfguvyz';
   border_w  constant text := '0145hjnp';
   h text := lower(coalesce(p_hash, ''));
   dir text := lower(coalesce(p_dir, ''));
   last_char text;
   parent text;
   t_neighbor text;
   t_border text;
   idx integer;
BEGIN
   IF h = '' THEN RAISE EXCEPTION 'geohash_adjacent: hash must not be empty'; END IF;
   IF dir NOT IN ('n','s','e','w') THEN
      RAISE EXCEPTION 'geohash_adjacent: dir must be one of n,s,e,w (got "%")', p_dir;
   END IF;
   last_char := right(h, 1);
   parent := left(h, char_length(h) - 1);
   IF (char_length(h) % 2) = 0 THEN
      IF dir = 'n' THEN t_neighbor := neighbor_n; t_border := border_n;
      ELSIF dir = 's' THEN t_neighbor := neighbor_s; t_border := border_s;
      ELSIF dir = 'e' THEN t_neighbor := neighbor_e; t_border := border_e;
      ELSE t_neighbor := neighbor_w; t_border := border_w; END IF;
   ELSE
      IF dir = 'n' THEN t_neighbor := neighbor_e; t_border := border_e;
      ELSIF dir = 's' THEN t_neighbor := neighbor_w; t_border := border_w;
      ELSIF dir = 'e' THEN t_neighbor := neighbor_n; t_border := border_n;
      ELSE t_neighbor := neighbor_s; t_border := border_s; END IF;
   END IF;
   IF parent <> '' AND position(last_char in t_border) > 0 THEN
      parent := geohash_adjacent(parent, dir);
   END IF;
   idx := position(last_char in t_neighbor);
   IF idx = 0 THEN
      RAISE EXCEPTION 'geohash_adjacent: invalid geohash character "%" in "%"', last_char, p_hash;
   END IF;
   RETURN parent || substr(base32, idx, 1);
END;
$$;

-- ------- geohash_decode_bbox (extracted) -------
CREATE OR REPLACE FUNCTION geohash_decode_bbox(p_geohash text)
RETURNS TABLE(lat_min double precision, lat_max double precision,
              lon_min double precision, lon_max double precision)
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   base32 text := '0123456789bcdefghjkmnpqrstuvwxyz';
   lat_lo double precision := -90.0;  lat_hi double precision := 90.0;
   lon_lo double precision := -180.0; lon_hi double precision := 180.0;
   is_even boolean := true; i integer; cd integer; mask integer; idx integer;
   c text; mid double precision;
BEGIN
   IF p_geohash IS NULL OR length(p_geohash) < 1 THEN
      RAISE EXCEPTION 'geohash_decode_bbox: geohash must be non-empty';
   END IF;
   FOR i IN 1..length(p_geohash) LOOP
      c := substr(p_geohash, i, 1);
      idx := position(c in base32) - 1;
      IF idx < 0 THEN RAISE EXCEPTION 'geohash_decode_bbox: invalid char "%" in "%"', c, p_geohash; END IF;
      cd := idx; mask := 16;
      WHILE mask > 0 LOOP
         IF is_even THEN
            mid := (lon_lo + lon_hi) / 2.0;
            IF (cd & mask) <> 0 THEN lon_lo := mid; ELSE lon_hi := mid; END IF;
         ELSE
            mid := (lat_lo + lat_hi) / 2.0;
            IF (cd & mask) <> 0 THEN lat_lo := mid; ELSE lat_hi := mid; END IF;
         END IF;
         is_even := NOT is_even; mask := mask / 2;
      END LOOP;
   END LOOP;
   lat_min := lat_lo; lat_max := lat_hi; lon_min := lon_lo; lon_max := lon_hi;
   RETURN NEXT;
END;
$$;

-- ------- geohash_cells_for_bbox (extracted) -------
CREATE OR REPLACE FUNCTION geohash_cells_for_bbox(
   p_lon_min double precision,
   p_lat_min double precision,
   p_lon_max double precision,
   p_lat_max double precision,
   p_precision integer
)
RETURNS SETOF text
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   sw_hash    text;
   row_start  text;
   cur        text;
   cur_bbox   record;
BEGIN
   -- Encode the SW corner to get our starting cell
   sw_hash := geohash_encode(p_lat_min, p_lon_min, p_precision);

   -- Walk rows south-to-north
   row_start := sw_hash;
   LOOP
      -- Walk columns west-to-east within this row
      cur := row_start;
      LOOP
         RETURN NEXT cur;

         -- Step east
         cur := geohash_adjacent(cur, 'e');
         SELECT * INTO cur_bbox FROM geohash_decode_bbox(cur);

         -- If this cell's west edge is past our east boundary, row is done
         EXIT WHEN cur_bbox.lon_min >= p_lon_max;
      END LOOP;

      -- Step north to the next row
      row_start := geohash_adjacent(row_start, 'n');
      SELECT * INTO cur_bbox FROM geohash_decode_bbox(row_start);

      -- If this row's south edge is past our north boundary, we're done
      EXIT WHEN cur_bbox.lat_min >= p_lat_max;
   END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION geohash_cells_for_bbox(
   p_lon_min double precision,
   p_lat_min double precision,
   p_lon_max double precision,
   p_lat_max double precision
)
RETURNS SETOF text
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   lat_span_miles double precision;
   lon_span_miles double precision;
   max_span       double precision;
   prec           integer;
BEGIN
   -- Approximate bbox span in miles
   -- 1 degree latitude  ~ 69 miles
   -- 1 degree longitude ~ 69 * cos(mid_lat) miles
   lat_span_miles := abs(p_lat_max - p_lat_min) * 69.0;
   lon_span_miles := abs(p_lon_max - p_lon_min) * 69.0
                     * cos(radians((p_lat_min + p_lat_max) / 2.0));
   max_span := greatest(lat_span_miles, lon_span_miles);

   -- Pick precision to match available indexes
   IF max_span > 20.0 THEN
      prec := 5;    -- ix_mapdata3: LEFT(geo_hash10, 5)
   ELSIF max_span > 1.0 THEN
      prec := 6;    -- ix_mapdata4: LEFT(geo_hash10, 6)
   ELSE
      prec := 8;    -- ix_mapdata_geo_hash8
   END IF;

   RETURN QUERY SELECT geohash_cells_for_bbox(
      p_lon_min, p_lat_min, p_lon_max, p_lat_max, prec
   );
END;
$$;

CREATE OR REPLACE FUNCTION geohash_cells_for_bbox(
   p_lon_min numeric,
   p_lat_min numeric,
   p_lon_max numeric,
   p_lat_max numeric,
   p_precision integer
)
RETURNS SETOF text
LANGUAGE sql IMMUTABLE
AS $$
   SELECT geohash_cells_for_bbox(
      p_lon_min::double precision,
      p_lat_min::double precision,
      p_lon_max::double precision,
      p_lat_max::double precision,
      p_precision
   );
$$;

CREATE OR REPLACE FUNCTION geohash_cells_for_bbox(
   p_lon_min numeric,
   p_lat_min numeric,
   p_lon_max numeric,
   p_lat_max numeric
)
RETURNS SETOF text
LANGUAGE sql IMMUTABLE
AS $$
   SELECT geohash_cells_for_bbox(
      p_lon_min::double precision,
      p_lat_min::double precision,
      p_lon_max::double precision,
      p_lat_max::double precision
   );
$$;

