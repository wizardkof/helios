/* SPDX-License-Identifier: MIT */
#include "../icd/mesa/src/virtio/vulkan/vn_renderer_helios_wait_result.h"

int main(void)
{
   if (helios_wire_vk_result((struct helios_wire_result) {
         HELIOS_WIRE_ERROR, HELIOS_VIRTIO_RESP_ERR_UNSPEC }) != VK_ERROR_UNKNOWN)
      return 1;
   if (helios_wire_vk_result((struct helios_wire_result) {
         HELIOS_WIRE_SUCCESS, 0 }) != VK_SUCCESS)
      return 2;
   if (helios_wire_vk_result((struct helios_wire_result) {
         HELIOS_WIRE_PENDING, 0 }) != VK_TIMEOUT)
      return 3;
   return 0;
}
