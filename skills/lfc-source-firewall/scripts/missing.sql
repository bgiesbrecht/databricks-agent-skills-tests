SELECT coalesce(string_agg(w, ' '), '') AS MISSING
FROM unnest(words(getvariable('WANT'))) t(w)
WHERE NOT EXISTS (SELECT 1 FROM unnest(words(getvariable('HAVE'))) h(h) WHERE NOT open_to_all(h) AND covers(h, w));
