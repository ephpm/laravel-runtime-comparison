<?php

use Illuminate\Support\Facades\Route;
use Illuminate\Support\Facades\DB;

Route::get('/', fn () => response()->json([
    'name' => 'laravel-runtime-benchmark',
    'laravel' => app()->version(),
]));

Route::prefix('api')->group(function (): void {
    Route::get('/health', fn () => response()->noContent());

    Route::get('/static', fn () => response()->json([
        'status' => true,
        'service' => 'laravel-runtime-benchmark',
        'version' => '1.0.0',
    ]));

    Route::get('/db', function () {
        $products = DB::table('products')
            ->select(['id', 'name', 'price', 'stock'])
            ->where('is_active', true)
            ->orderBy('id')
            ->limit(20)
            ->get();

        return response()->json([
            'database' => DB::connection()->getName(),
            'product_count' => DB::table('products')->where('is_active', true)->count(),
            'user_count' => DB::table('users')->count(),
            'inventory_value' => (float) DB::table('products')
                ->where('is_active', true)
                ->selectRaw('SUM(price * stock) AS total')
                ->value('total'),
            'products' => $products,
        ]);
    });

    Route::get('/cpu', function () {
        $checksum = 0;

        for ($i = 1; $i <= 1000; $i++) {
            $checksum = ($checksum + (($i * $i) % 9973)) % 1000003;
        }

        return response()->json([
            'checksum' => $checksum,
            'items' => 1000,
        ]);
    });
});
