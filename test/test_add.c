#include "add.h"
#include "unity_fixture.h"

TEST_GROUP(add);

TEST_SETUP(add) {
}

TEST_TEAR_DOWN(add) {
}

TEST(add, zeros_should_add_to_zero) {
    TEST_ASSERT_EQUAL(0, add(0, 0));
}

TEST(add, zero_and_one_should_add_to_one) {
    TEST_ASSERT_EQUAL(1, add(0, 1));
}

TEST(add, one_and_zero_should_add_to_one) {
    TEST_ASSERT_EQUAL(1, add(1, 0));
}

TEST(add, one_and_two_should_add_to_three) {
    TEST_ASSERT_EQUAL(3, add(1, 2));
}

TEST(add, two_and_three_should_add_to_five) {
    TEST_ASSERT_EQUAL(5, add(2, 3));
}
