<?php

namespace Database\Seeders;

use App\Models\User;
use App\Models\Product;
use Illuminate\Database\Console\Seeds\WithoutModelEvents;
use Illuminate\Database\Seeder;

class DatabaseSeeder extends Seeder
{
    use WithoutModelEvents;

    /**
     * Seed the application's database.
     */
    public function run(): void
    {
        for ($i = 1; $i <= 100; $i++) {
            User::create([
                'name' => 'Benchmark User '.$i,
                'email' => 'benchmark-'.$i.'@example.com',
                'password' => 'benchmark-password',
            ]);
        }

        for ($i = 1; $i <= 1000; $i++) {
            Product::create([
                'name' => 'Benchmark Product '.$i,
                'sku' => 'BENCH-'.str_pad((string) $i, 6, '0', STR_PAD_LEFT),
                'price' => 10 + (($i * 17) % 49000) / 100,
                'stock' => ($i * 37) % 1001,
                'is_active' => $i % 10 !== 0,
            ]);
        }
    }
}
