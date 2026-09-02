<?php

declare(strict_types=1);

/**
 * Merge a Composer overlay into a composer.json.
 *
 * Used by the ephpm-worker image to add the ePHPm worker packages on top of
 * the shared app/composer.json without editing the file every other runtime
 * image consumes. Only the "repositories" and "require" keys are merged; keys
 * beginning with "_" are treated as comments and dropped.
 *
 * Usage: php merge-composer.php <composer.json> <overlay.json>
 */

[, $target, $overlayPath] = $argv + [null, null, null];

if ($target === null || $overlayPath === null) {
    fwrite(STDERR, "Usage: php merge-composer.php <composer.json> <overlay.json>\n");
    exit(1);
}

$decode = static function (string $path): array {
    $raw = file_get_contents($path);
    if ($raw === false) {
        fwrite(STDERR, "Cannot read {$path}\n");
        exit(1);
    }

    $data = json_decode($raw, true);
    if (!is_array($data)) {
        fwrite(STDERR, "Invalid JSON in {$path}: " . json_last_error_msg() . "\n");
        exit(1);
    }

    return $data;
};

$composer = $decode($target);
$overlay = $decode($overlayPath);

foreach ($overlay as $key => $value) {
    if (str_starts_with((string) $key, '_')) {
        continue;
    }

    if ($key === 'repositories') {
        // The app's composer.json has no "repositories" key; keep any that
        // appear later upstream by merging rather than replacing. Named
        // (object) form is used so entries stay individually addressable.
        $existing = $composer['repositories'] ?? [];
        $composer['repositories'] = array_merge((array) $existing, (array) $value);
        continue;
    }

    if ($key === 'require') {
        $composer['require'] = array_merge($composer['require'] ?? [], (array) $value);
        continue;
    }

    $composer[$key] = $value;
}

$encoded = json_encode(
    $composer,
    JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE
);

if ($encoded === false) {
    fwrite(STDERR, "Failed to encode merged composer.json\n");
    exit(1);
}

file_put_contents($target, $encoded . "\n");

printf("Merged %s into %s\n", basename($overlayPath), basename($target));
