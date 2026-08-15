<?php

namespace Tests\Feature;

use App\Models\Product;
use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\TestCase;

class DatabaseBenchmarkTest extends TestCase
{
    use RefreshDatabase;

    public function test_database_endpoint_executes_real_queries(): void
    {
        User::factory()->count(2)->create();
        Product::factory()->count(3)->create(['is_active' => true]);

        $response = $this->getJson('/api/db');

        $response->assertOk()
            ->assertJsonPath('database', 'sqlite')
            ->assertJsonPath('product_count', 3)
            ->assertJsonPath('user_count', 2)
            ->assertJsonCount(3, 'products');
    }
}
