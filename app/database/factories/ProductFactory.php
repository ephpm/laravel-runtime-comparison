<?php

namespace Database\Factories;

use Illuminate\Database\Eloquent\Factories\Factory;

/** @extends Factory<\App\Models\Product> */
class ProductFactory extends Factory
{
    public function definition(): array
    {
        $number = $this->faker->unique()->numberBetween(1, 999999);

        return [
            'name' => 'Benchmark Product '.$number,
            'sku' => 'SKU-'.str_pad((string) $number, 6, '0', STR_PAD_LEFT),
            'price' => $this->faker->randomFloat(2, 5, 500),
            'stock' => $this->faker->numberBetween(0, 1000),
            'is_active' => $this->faker->boolean(90),
        ];
    }
}
